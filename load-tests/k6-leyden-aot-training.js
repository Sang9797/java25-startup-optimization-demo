import http from 'k6/http';
import { check, sleep } from 'k6';

const baseUrl = __ENV.K6_BASE_URL || 'http://127.0.0.1:8080';

export const options = {
  summaryTrendStats: ['avg', 'min', 'med', 'max', 'p(90)', 'p(95)', 'p(99)']
};

function requestSet(seed) {
  const userId = 100 + (seed % 900);
  const orderId = 200 + (seed % 900);
  const productId = 300 + (seed % 900);

  return [
    ['GET', `${baseUrl}/health`, null],
    ['GET', `${baseUrl}/hello`, null],
    ['GET', `${baseUrl}/compute`, null],
    ['GET', `${baseUrl}/api/users/${userId}`, null],
    ['GET', `${baseUrl}/api/orders/${orderId}`, null],
    ['GET', `${baseUrl}/api/products/${productId}`, null],
    ['GET', `${baseUrl}/dependencies`, null],
    ['GET', `${baseUrl}/dependencies/latest`, null]
  ];
}

export default function () {
  const seed = (__VU * 10000) + __ITER;
  const responses = http.batch(requestSet(seed));

  const paths = [
    '/health',
    '/hello',
    '/compute',
    '/api/users',
    '/api/orders',
    '/api/products',
    '/dependencies',
    '/dependencies/latest'
  ];

  responses.forEach((response, index) => {
    check(response, {
      [`${paths[index]} status 200`]: (r) => r.status === 200
    });
  });

  sleep(0.1);
}
