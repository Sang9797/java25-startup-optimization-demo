import http from 'k6/http';
import { check, sleep } from 'k6';

const baseUrl = __ENV.K6_BASE_URL || 'http://127.0.0.1:8080';

export const options = {
  thresholds: {
    http_req_failed: ['rate<0.01'],
    http_req_duration: ['p(95)<250']
  }
};

export default function () {
  const endpoints = [
    '/health',
    '/api/users/123',
    '/api/orders/456',
    '/api/products/789'
  ];

  for (const endpoint of endpoints) {
    const response = http.get(`${baseUrl}${endpoint}`);
    check(response, {
      [`${endpoint} status 200`]: (r) => r.status === 200
    });
  }

  sleep(0.1);
}
