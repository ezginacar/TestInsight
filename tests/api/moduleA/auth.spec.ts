import { test} from '@playwright/test';

const BASE_URL = 'https://api.example.com';

test.describe('Auth Tests @smoke', () => {
  test('auth test1', async ({ request }) => {
    await console.log('auth test 01');
  });

  test('auth test 2', async ({ request }) => {
    await console.log('auth test 02');
  });

  test('auth test 3', async ({ request }) => {
    await console.log('auth test 03');
  });

  test('auth test4', async ({ request }) => {
    await console.log('auth test 04');
  });
});