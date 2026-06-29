function handler(event) {
  var request = event.request;
  var headers = request.headers;
  // 이미 쿼리스트링이 있으면 변환하지 않음
  if (request.querystring && Object.keys(request.querystring).length > 0) {
    return request;
  }
  var isMobile = headers['cloudfront-is-mobile-viewer'] && headers['cloudfront-is-mobile-viewer'].value === 'true';
  if (isMobile) {
    request.querystring['w'] = { value: '480' };
    request.querystring['h'] = { value: '320' };
    request.querystring['type'] = { value: 'mobile' };
  } else {
    request.querystring['w'] = { value: '1920' };
    request.querystring['h'] = { value: '1080' };
    request.querystring['type'] = { value: 'desktop' };
  }
  return request;
}
