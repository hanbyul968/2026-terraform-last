function handler(event) {
  var request = event.request;
  var response = event.response;
  var type = 'desktop';
  if (request.querystring && request.querystring['type'] && request.querystring['type'].value) {
    type = request.querystring['type'].value;
  }
  response.headers['x-device-type'] = { value: type };
  response.headers['x-resized'] = { value: 'true' };
  return response;
}
