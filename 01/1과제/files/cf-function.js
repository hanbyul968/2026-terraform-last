// CloudFront Functions (cloudfront-js-2.0) - viewer-request
// /index  -> /index.html  (text/html)
// /main   -> /main.jpeg   (image/jpeg)
function handler(event) {
    var request = event.request;
    var uri = request.uri;

    if (uri === '/index' || uri === '/index/') {
        request.uri = '/index.html';
    } else if (uri === '/main' || uri === '/main/') {
        request.uri = '/main.jpeg';
    }

    return request;
}
