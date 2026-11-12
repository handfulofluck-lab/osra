// Fills the download link from /android/latest.json (ADR-0039 D4). The page reads the manifest only to show
// the link, version and size; the app itself checks the manifest's Ed25519 signature before it
// trusts it, so nothing here is a security control. No manifest yet = the "still being tested" line stays.
(function () {
  var ready = document.getElementById("dl-ready");
  if (!ready) return;
  fetch("/android/latest.json", { cache: "no-store" })
    .then(function (r) { return r.ok ? r.json() : null; })
    .then(function (m) {
      if (!m || typeof m.url !== "string" || m.url.indexOf("https://osratech.com/android/") !== 0) return;
      var link = document.getElementById("dl-link");
      link.href = m.url;
      var mb = m.size ? " · " + (m.size / 1048576).toFixed(1) + " MB" : "";
      document.getElementById("dl-meta").textContent = "Version " + String(m.versionName || "") + mb;
      ready.hidden = false;
      document.getElementById("dl-wait").hidden = true;
    })
    .catch(function () { /* keep the waiting line */ });
})();
