// Fills the download link from /android/latest.json (ADR-0039 D4). The page reads the manifest only to show
// the link, version, size and SHA-256; the app itself checks the manifest's Ed25519 signature before it
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
      if (typeof m.sha256 === "string" && /^[0-9a-f]{64}$/.test(m.sha256)) {
        var sha = document.getElementById("dl-sha");
        sha.textContent = "";
        sha.appendChild(document.createElement("br"));
        sha.appendChild(document.createTextNode(document.documentElement.lang === "ar" ? "بصمة SHA-256 للملف: " : "File SHA-256: "));
        var code = document.createElement("code");
        code.textContent = m.sha256;
        sha.appendChild(code);
      }
      ready.hidden = false;
      document.getElementById("dl-wait").hidden = true;
    })
    .catch(function () { /* keep the waiting line */ });
})();
