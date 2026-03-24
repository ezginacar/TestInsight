import { test, expect } from '@playwright/test';


  test('Api beta tests 01', async ({ request }) => {
    await console.log('beta test module 01');
  });

  test('Api beta tests 02', async ({ request }) => {
    expect(false).toBeTruthy();
  });

  test('Api beta tests 03', async ({ request }) => {
    await console.log('beta test module 03');
  });

  test('Api beta tests 04', async ({ request }) => {
    await console.log('beta test module 04');
  });


  