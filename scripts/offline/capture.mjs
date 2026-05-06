#!/usr/bin/env node
import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { spawn } from "node:child_process";
import { chromium } from "playwright";

const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");

/** Wait for window load, then (best-effort) network idle, then a fixed settle for hydration / late requests. */
const PAGE_NAV_TIMEOUT_MS = 180_000;
const PAGE_NETWORK_IDLE_TIMEOUT_MS = 90_000;
const PAGE_SETTLE_AFTER_IDLE_MS = 2_500;
const SINGLE_FILE_CMD_TIMEOUT_MS = 300_000;

/** Extra SingleFile browser waits so dynamic JS and lazy assets finish before capture. */
const SINGLE_FILE_BROWSER_FLAGS = [
  "--browser-wait-until",
  "networkIdle",
  "--browser-wait-until-delay",
  "2500",
  "--browser-wait-delay",
  "2000",
  "--browser-load-max-time",
  "180000",
  "--browser-capture-max-time",
  "180000",
  "--load-deferred-images-max-idle-time",
  "4000",
];

function delay(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/**
 * After navigation, give scripts and in-flight fetches time to finish (sites with perpetual
 * connections skip networkidle and still get the post-load settle delay).
 */
async function settlePageAfterNavigation(page) {
  try {
    await page.waitForLoadState("networkidle", { timeout: PAGE_NETWORK_IDLE_TIMEOUT_MS });
  } catch {
    // Long-polling / analytics keep connections open; load + settle still helps hydration.
  }
  await delay(PAGE_SETTLE_AFTER_IDLE_MS);
}

/** Skip domain cookie files for YouTube — yt-dlp / secrets handle those separately. */
function isYoutubeHostname(hostname) {
  const h = String(hostname).toLowerCase();
  return (
    h === "youtu.be" ||
    h === "youtube.com" ||
    h === "www.youtube.com" ||
    h.endsWith(".youtube.com")
  );
}

async function resolveCookiesFileForUrl(urlString) {
  let hostname;
  try {
    hostname = new URL(urlString).hostname.toLowerCase();
  } catch {
    return null;
  }
  if (isYoutubeHostname(hostname)) {
    return null;
  }
  const cookiesDir = path.join(REPO_ROOT, "cookies");
  const candidates = [path.join(cookiesDir, `${hostname}.txt`)];
  if (hostname.startsWith("www.")) {
    candidates.push(path.join(cookiesDir, `${hostname.slice(4)}.txt`));
  }
  for (const candidate of candidates) {
    try {
      await fs.access(candidate);
      return candidate;
    } catch {
      // try next
    }
  }
  return null;
}

function parseNetscapeCookies(textValue) {
  const httpOnlyRegExp = /^#HttpOnly_(.*)/;
  return textValue
    .split(/\r\n|\n/)
    .filter((line) => line.trim() && (!/^#/.test(line) || httpOnlyRegExp.test(line)))
    .map((line) => {
      let httpOnly = httpOnlyRegExp.test(line);
      if (httpOnly) {
        line = line.replace(httpOnlyRegExp, "$1");
      }
      const values = line.split("\t");
      if (values.length === 7) {
        return {
          domain: values[0],
          path: values[2],
          secure: values[3] === "TRUE",
          expires: values[4] ? Number(values[4]) : undefined,
          name: values[5],
          value: values[6],
          httpOnly,
        };
      }
      return null;
    })
    .filter(Boolean);
}

function toPlaywrightCookies(parsed) {
  const now = Date.now() / 1000;
  return parsed
    .filter((c) => {
      if (c.expires == null || c.expires === 0) return true;
      return c.expires > now;
    })
    .map((c) => ({
      name: c.name,
      value: c.value,
      domain: c.domain,
      path: c.path || "/",
      ...(c.expires ? { expires: Math.floor(c.expires) } : {}),
      httpOnly: Boolean(c.httpOnly),
      secure: Boolean(c.secure),
      sameSite: "Lax",
    }));
}

async function addCookiesFromFile(context, cookiesFilePath) {
  if (!cookiesFilePath) return;
  try {
    const text = await fs.readFile(cookiesFilePath, "utf8");
    const parsed = parseNetscapeCookies(text);
    const cookies = toPlaywrightCookies(parsed);
    if (cookies.length) {
      await context.addCookies(cookies);
    }
  } catch (err) {
    console.error(`[capture] Failed to apply cookies for Playwright: ${err.message}`);
  }
}

function parseArgs(argv) {
  const args = {};
  for (let i = 2; i < argv.length; i += 1) {
    const token = argv[i];
    if (!token.startsWith("--")) continue;
    const key = token.slice(2);
    const next = argv[i + 1];
    if (!next || next.startsWith("--")) {
      args[key] = "true";
      continue;
    }
    args[key] = next;
    i += 1;
  }
  return args;
}

function sanitizeName(value) {
  return value
    .toLowerCase()
    .replace(/[^a-z0-9._-]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 90) || "page";
}

function runCmd(command, commandArgs, timeoutMs = 180000) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, commandArgs, { stdio: "inherit" });
    const timer = setTimeout(() => {
      child.kill("SIGTERM");
      setTimeout(() => child.kill("SIGKILL"), 5000);
      reject(new Error(`${command} timed out after ${timeoutMs}ms`));
    }, timeoutMs);

    child.on("exit", (code) => {
      clearTimeout(timer);
      if (code === 0) resolve();
      else reject(new Error(`${command} exited with code ${code}`));
    });
    child.on("error", (error) => {
      clearTimeout(timer);
      reject(error);
    });
  });
}

async function singleFileCapture(url, outputPath, cookiesFilePath) {
  const args = ["--no-install", "single-file", ...SINGLE_FILE_BROWSER_FLAGS];
  if (cookiesFilePath) {
    args.push("--browser-cookies-file", path.resolve(cookiesFilePath));
  }
  args.push(url, outputPath);
  await runCmd("npx", args, SINGLE_FILE_CMD_TIMEOUT_MS);
}

async function mhtmlCapture(url, outputPath, cookiesFilePath) {
  const browser = await chromium.launch({ headless: true });
  const context = await browser.newContext();
  await addCookiesFromFile(context, cookiesFilePath);
  const page = await context.newPage();
  await page.goto(url, { waitUntil: "load", timeout: PAGE_NAV_TIMEOUT_MS });
  await settlePageAfterNavigation(page);
  const client = await context.newCDPSession(page);
  const result = await client.send("Page.captureSnapshot", { format: "mhtml" });
  await fs.writeFile(outputPath, result.data, "utf8");
  await browser.close();
}

async function crawlLinks(url, limit, cookiesFilePath) {
  const browser = await chromium.launch({ headless: true });
  const context = await browser.newContext();
  await addCookiesFromFile(context, cookiesFilePath);
  const page = await context.newPage();
  await page.goto(url, { waitUntil: "load", timeout: PAGE_NAV_TIMEOUT_MS });
  await settlePageAfterNavigation(page);

  const baseHost = new URL(url).host;
  const links = await page.$$eval("a[href]", (elements) =>
    elements.map((e) => e.href).filter(Boolean)
  );
  await browser.close();

  const unique = [];
  for (const href of links) {
    try {
      const parsed = new URL(href);
      if (parsed.host !== baseHost) continue;
      if (unique.includes(parsed.href)) continue;
      unique.push(parsed.href);
      if (unique.length >= limit) break;
    } catch {
      // Ignore malformed links.
    }
  }
  return unique;
}

async function main() {
  const args = parseArgs(process.argv);
  const mode = args.mode || "singlefile";
  const url = args.url;
  const outputDir = args.output || "downloads";
  const crawlLimit = Number(args.crawlLimit || "8");

  if (!url) {
    throw new Error("--url is required");
  }

  await fs.mkdir(outputDir, { recursive: true });
  const hostname = sanitizeName(new URL(url).hostname);
  const stamp = new Date().toISOString().replace(/[:.]/g, "-");

  const cookiesFilePath = await resolveCookiesFileForUrl(url);
  if (cookiesFilePath) {
    const rel = path.relative(REPO_ROOT, cookiesFilePath);
    console.error(`[capture] Using cookies file: ${rel}`);
  }

  if (mode === "singlefile") {
    const outFile = path.join(outputDir, `${hostname}-${stamp}.offline.html`);
    await singleFileCapture(url, outFile, cookiesFilePath);
    return;
  }

  if (mode === "mhtml") {
    const outFile = path.join(outputDir, `${hostname}-${stamp}.mhtml`);
    await mhtmlCapture(url, outFile, cookiesFilePath);
    return;
  }

  if (mode === "crawl") {
    const allLinks = [url, ...(await crawlLinks(url, crawlLimit, cookiesFilePath))];
    for (const target of allLinks) {
      const targetUrl = new URL(target);
      const slug = sanitizeName(`${targetUrl.hostname}${targetUrl.pathname}`);
      const outFile = path.join(outputDir, `${slug}-${stamp}.offline.html`);
      await singleFileCapture(target, outFile, cookiesFilePath);
    }
    return;
  }

  throw new Error(`Unsupported mode: ${mode}`);
}

main().catch((error) => {
  console.error(`[capture] ${error.message}`);
  process.exit(1);
});
