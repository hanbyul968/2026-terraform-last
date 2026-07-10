// CloudFront Function - Viewer Response
// Runtime: cloudfront-js-2.0
// 응답 반환 직전에 X-Device-Type / X-Resized 헤더를 추가한다.
// 디바이스 타입은 쿼리스트링의 type 파라미터로 판별한다.

function handler(event) {
    var request = event.request;
    var response = event.response;

    var deviceType = 'desktop';
    if (request.querystring && request.querystring.type && request.querystring.type.value) {
        deviceType = request.querystring.type.value;
    }

    response.headers['x-device-type'] = { value: deviceType };
    response.headers['x-resized']     = { value: 'true' };

    return response;
}
