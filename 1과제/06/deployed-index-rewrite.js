function handler(event) {
  var request = event.request;
  var uri = request.uri;

  // Root must remain unchanged so DefaultRootObject performs the canonical
  // mapping to index.html before CloudFront stores the cache entry.
  if (uri === '/') {
    return request;
  }

  var leaf = uri.substring(uri.lastIndexOf('/') + 1);
  if (uri.endsWith('/') || leaf.indexOf('.') === -1) {
    request.uri = '/index.html';
  }

  return request;
}
