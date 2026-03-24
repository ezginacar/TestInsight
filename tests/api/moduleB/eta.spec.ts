import { test, expect } from '@playwright/test';

test.describe('Eta Tests', () => {

  test('Api eta tests 01', { tag: ['@smoke'] }, async ({ request }) => {
    console.log('eta test 01');
  });

  test('Api eta tests 02', async ({ request }) => {
    console.log('eta test 02');
  });

  test('Api eta tests 03', async ({ request }) => {
    console.log('eta test 03');
    expect(false).toBeTruthy();
  });

});