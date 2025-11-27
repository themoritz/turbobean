import { test, expect, beforeAll, afterAll, describe } from 'bun:test';
import puppeteer from 'puppeteer';
import { spawn } from 'child_process';
import { join } from 'path';

const __dirname = import.meta.dir;

const SERVER_URL = 'http://localhost:8080';
const TEST_FILE = join(__dirname, 'test_data.bean');
const REPO_ROOT = join(__dirname, '..', '..');
const BINARY_PATH = join(REPO_ROOT, 'zig-out', 'bin', 'turbobean');
const HEADLESS = process.env.HEADLESS !== 'false';

let server = null;
let browser = null;
let page = null;

beforeAll(async () => {
  console.log('Starting turbobean server...');
  await new Promise((resolve, reject) => {
    server = spawn(BINARY_PATH, [TEST_FILE, '--server'], {
      stdio: 'pipe',
      cwd: REPO_ROOT,
    });

    // Turbobean mostly outputs to stderr for now which is normal
    server.stderr.on('data', (data) => {
      const output = data.toString();
      console.log('[server]', data.toString().trim());
      if (output.includes('Listening on')) {
        resolve();
      }
    });

    server.on('error', (err) => {
      reject(new Error(`Failed to start server: ${err.message}`));
    });

    const timeoutId = setTimeout(() => {
      reject(new Error('Server failed to start within 10 seconds'))
    }, 1000);

    server.stdout.once('data', () => {
      clearTimeout(timeoutId);
    });
  });

  console.log('Launching browser...');
  browser = await puppeteer.launch({
    headless: HEADLESS ? 'new' : false,
    args: ['--no-sandbox', '--disable-setuid-sandbox']
  });

  page = await browser.newPage();
  await page.setViewport({ width: 1280, height: 800 });

  // Enable console logging from the page
  page.on('console', msg => {
    console.log('[browser console]', msg.text());
  });

  page.on('pageerror', error => {
    console.error('[browser error]', error.message);
  });
}, 10000); // 10 second timeout for setup

afterAll(async () => {
  if (browser) {
    await browser.close();
  }

  if (server) {
    console.log('Stopping server...');
    try {
      await fetch(`${SERVER_URL}/shutdown`);
    } catch (e) {
      server.kill('SIGTERM');
    }

    await new Promise((resolve) => {
      server.on('exit', resolve);
      setTimeout(() => {
        if (server) {
          server.kill('SIGKILL');
        }
        resolve();
      }, 1000);
    });
  }
});

describe('TurboBean Server', () => {
  describe('Balance Sheet', () => {
    beforeAll(async () => {
      await page.goto(`${SERVER_URL}/balance_sheet`, { waitUntil: 'domcontentloaded' });
      await Bun.sleep(10);
    });

    test('page loads', async () => {
      const bodyHandle = await page.$('body');
      expect(bodyHandle).not.toBeNull();
    });

    test('displays Savings account', async () => {
      const pageContent = await page.evaluate(() => document.body.innerText);
      expect(pageContent).toContain('Savings');
    });

    test('shows expected checking balance (2030.00)', async () => {
      const pageContent = await page.evaluate(() => document.body.innerText);
      expect(pageContent.includes('2,030')).toBe(true);
    });

    test('shows expected savings balance (5000.00)', async () => {
      const pageContent = await page.evaluate(() => document.body.innerText);
      expect(pageContent.includes('5,000')).toBe(true);
    });
  });

  describe('Income Statement', () => {
    beforeAll(async () => {
      await page.goto(`${SERVER_URL}/income_statement`, { waitUntil: 'domcontentloaded' });
      await Bun.sleep(10);
    });

    test('page loads', async () => {
      const bodyHandle = await page.$('body');
      expect(bodyHandle).not.toBeNull();
    });

    test('shows expected salary amount (3000.00)', async () => {
      const pageContent = await page.evaluate(() => document.body.innerText);
      expect(pageContent.includes('3000') || pageContent.includes('3,000')).toBe(true);
    });

    test('displays Rent expense', async () => {
      const pageContent = await page.evaluate(() => document.body.innerText);
      expect(pageContent).toContain('Rent');
    });

    test('shows expected rent amount (1200.00)', async () => {
      const pageContent = await page.evaluate(() => document.body.innerText);
      expect(pageContent.includes('1200') || pageContent.includes('1,200')).toBe(true);
    });

    test('displays Groceries expense', async () => {
      const pageContent = await page.evaluate(() => document.body.innerText);
      expect(pageContent).toContain('Groceries');
    });

    test('shows expected groceries total (270.00)', async () => {
      const pageContent = await page.evaluate(() => document.body.innerText);
      expect(pageContent).toContain('270');
    });
  });

  describe('Journal', () => {
    beforeAll(async () => {
      const encodedAccount = encodeURIComponent('Assets:Checking');
      await page.goto(`${SERVER_URL}/journal/${encodedAccount}`, { waitUntil: 'domcontentloaded' });
      await Bun.sleep(10);
    });

    test('page loads', async () => {
      const bodyHandle = await page.$('body');
      expect(bodyHandle).not.toBeNull();
    });

    test('displays account name', async () => {
      const pageContent = await page.evaluate(() => document.body.innerText);
      expect(pageContent).toContain('Assets:Checking');
    });

    test('displays transaction information', async () => {
      const pageContent = await page.evaluate(() => document.body.innerText);
      const hasTransactionInfo =
        pageContent.includes('Opening balance') &&
        pageContent.includes('Salary') &&
        pageContent.includes('Rent payment');
      expect(hasTransactionInfo).toBe(true);
    });
  });

  describe('Static Assets', () => {
    test('static endpoint responds', async () => {
      const response = await fetch(`${SERVER_URL}/static/style.css`);
      expect(response.ok || response.status === 404).toBe(true);
    });
  });
});
