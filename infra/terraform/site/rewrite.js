// CloudFront viewer-request function for osratech.com (see main.tf).
function handler(event) {
  var request = event.request;
  var host = request.headers.host ? request.headers.host.value : "";

  // One canonical host.
  if (host === "www.osratech.com") {
    return {
      statusCode: 301,
      statusDescription: "Moved Permanently",
      headers: { location: { value: "https://osratech.com" + request.uri } },
    };
  }

  // /privacy and /privacy/ serve /privacy/index.html; files with an extension pass through.
  var uri = request.uri;
  if (uri.endsWith("/")) {
    request.uri = uri + "index.html";
  } else if (uri.lastIndexOf(".") < uri.lastIndexOf("/") || uri.indexOf(".") === -1) {
    request.uri = uri + "/index.html";
  }
  return request;
}
