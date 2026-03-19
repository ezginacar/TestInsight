import { test, expect } from '@playwright/test';

test('delta ui test 01', async ({ page }) => {
  await console.log('alpha test module 01');
});


test('deltaui test 02', async ({ page }) => {
  await console.log('alpha test module 02');
  expect(false).toBeTruthy();
});


test.skip('delta ui test 03', async ({ page }) => {
  await console.log('alpha test module 03');
});

test.skip('delta ui test 04', async ({ page }) => {
  await console.log('alpha test module 03');
});