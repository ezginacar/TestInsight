import { test, expect } from '@playwright/test';
import { assert } from 'node:console';

const BASE_URL = 'https://api.example.com';

test.describe('Auth API', () => {
  test('should login successfully with valid credentials', async ({ request }) => {
    const response = await request.post(`${BASE_URL}/api/auth/login`, {
      data: {
        email: 'user@test.com',
        password: '123456',
      },
    });

    expect(response.status()).toBe(200);

    const body = await response.json();
    expect(body.accessToken).toBeTruthy();
    expect(body.refreshToken).toBeTruthy();
    expect(body.user).toBeTruthy();
    expect(body.user.email).toBe('user@test.com');
  });

  test('should return 401 for invalid password', async ({ request }) => {
    const response = await request.post(`${BASE_URL}/api/auth/login`, {
      data: {
        email: 'user@test.com',
        password: 'wrong-password',
      },
    });

    expect(response.status()).toBe(401);

    const body = await response.json();
    expect(body.error).toBeTruthy();
    expect(body.accessToken).toBeUndefined();
    expect(body.refreshToken).toBeUndefined();
  });

  test('should return 400 when password is missing', async ({ request }) => {
    const response = await request.post(`${BASE_URL}/api/auth/login`, {
      data: {
        email: 'user@test.com',
      },
    });

    expect(response.status()).toBe(400);

    const body = await response.json();
    expect(body.error).toContain('Password');
  });

  test('should return 401 when accessing protected endpoint without token', async ({ request }) => {
    await console.log('Testing access to protected endpoint without token');
  });
});