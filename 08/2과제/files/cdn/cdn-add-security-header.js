function handler(event) {
  var response = event.response;
  response.headers['x-custom-header'] = { value: 'wsc2026' };
  return response;
}
