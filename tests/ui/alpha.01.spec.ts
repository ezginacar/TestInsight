import { test, expect } from '@playwright/test';
import { assert } from 'node:console';

test('alpha ui test 01', async ({ page }) => {
  await console.log('alpha test module 01');
});


test('alpha ui test 02', async ({ page }) => {
  await console.log('alpha test module 02');
  expect(false).toBeTruthy();
});


test.skip('alpha ui test 03', async ({ page }) => {
  await console.log('alpha test module 03');
});