/*
Run this in your browser console while https://www.youtube.com is open.
It prints the VISITOR_DATA value and copies it to your clipboard.
Then paste that value into scripts/download/youtube_visitor_data.txt
*/

(() => {
  const ytcfg = window.ytcfg;
  const value =
    (ytcfg && typeof ytcfg.get === "function" && ytcfg.get("VISITOR_DATA")) ||
    (ytcfg && ytcfg.data_ && ytcfg.data_.VISITOR_DATA) ||
    "";

  if (!value) {
    console.error(
      "VISITOR_DATA was not found. Make sure you are on youtube.com and the page is fully loaded."
    );
    return;
  }

  const output = String(value).trim();
  console.log("VISITOR_DATA:");
  console.log(output);

  if (navigator.clipboard && navigator.clipboard.writeText) {
    navigator.clipboard
      .writeText(output)
      .then(() => console.log("Copied to clipboard."))
      .catch(() =>
        console.warn("Clipboard copy failed. Copy the printed value manually.")
      );
  } else {
    console.warn("Clipboard API unavailable. Copy the printed value manually.");
  }
})();
