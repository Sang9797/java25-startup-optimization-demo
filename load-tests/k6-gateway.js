import http from 'k6/http';
import { check, sleep } from 'k6';

const baseUrl = __ENV.K6_BASE_URL || 'http://127.0.0.1:8080';

const thresholdsEnabled = (__ENV.K6_DISABLE_THRESHOLDS || '').toLowerCase() !== 'true';

export const options = {
  summaryTrendStats: ['avg', 'min', 'med', 'max', 'p(90)', 'p(95)', 'p(99)'],
  thresholds: thresholdsEnabled ? {
    http_req_failed: ['rate<0.01'],
    http_req_duration: ['p(95)<250']
  } : {}
};

export default function () {
  const endpoints = [
    '/health',
    '/api/users/123',
    '/api/orders/456',
    '/api/products/789',
    '/dependencies'
  ];

  for (const endpoint of endpoints) {
    const response = http.get(`${baseUrl}${endpoint}`);
    check(response, {
      [`${endpoint} status 200`]: (r) => r.status === 200
    });
  }

  sleep(0.1);
}
