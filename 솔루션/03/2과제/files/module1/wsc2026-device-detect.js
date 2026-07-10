// CloudFront Function - Viewer Request
// Runtime: cloudfront-js-2.0
// 디바이스 타입을 판별해 쿼리스트링 w/h/type 을 동적으로 삽입한다.
// 이미 쿼리스트링이 존재하는 요청은 원본 값을 그대로 유지한다.

function handler(event) {
    var request = event.request;
    var qs = request.querystring;

    // 쿼리스트링이 하나라도 있으면 그대로 통과 (기존 값 유지)
    if (Object.keys(qs).length > 0) {
        return request;
    }

    var ua = '';
    if (request.headers['user-agent'] && request.headers['user-agent'].value) {
        ua = request.headers['user-agent'].value;
    }

    var isMobile = /Mobile|Android|iPhone|iPad|iPod|Windows Phone|BlackBerry|Opera Mini|IEMobile/i.test(ua);

    if (isMobile) {
        request.querystring = {
            w:    { value: '480' },
            h:    { value: '320' },
            type: { value: 'mobile' }
        };
    } else {
        request.querystring = {
            w:    { value: '1920' },
            h:    { value: '1080' },
            type: { value: 'desktop' }
        };
    }

    return request;
}
