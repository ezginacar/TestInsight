import { test, expect } from '@playwright/test';

test.describe('IOTA Tests', () => {

  test('Api eta tests 01', { tag: ['@smoke'] }, async ({ request }) => {
    console.log('iota test 01');
  });

  test('Api iota tests 02', async ({ request }) => {
    console.log('iotata test 02');
  });

  test('Api iotata tests 03 @smoke', async ({ request }) => {
    console.log('iota test 03 ');
    expect(true).toBeTruthy();
  });

});