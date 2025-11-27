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
      const output = data.toString().trim();
      if (!output.includes('[info]')) {
        console.log('[server]', output);
      }
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
    test('page loads', async () => {
      await goto('balance_sheet')
      const bodyHandle = await page.$('body');
      expect(bodyHandle).not.toBeNull();
    });
  });

  describe('Income Statement', () => {
    test('page loads', async () => {
      await goto('income_statement')
      const bodyHandle = await page.$('body');
      expect(bodyHandle).not.toBeNull();
    });
  });

  describe('Journal', () => {
    test('Plain', async () => {
      await goto('journal/Assets:Checking');
      const transactions = await getTransactions();

      const expected = [
        { narration: '', change: '', balance: '' }, // Open
        { narration: 'Opening balances', change: '1,000.00 USD', balance: '1,000.00 USD' },
        { narration: 'Salary', change: '3,000.00 USD', balance: '4,000.00 USD' },
        { narration: 'Groceries', change: '-150.00 USD', balance: '3,850.00 USD' },
        { narration: 'Credit card payment', change: '-500.00 USD', balance: '3,350.00 USD' },
        { narration: 'Buy AAPL', change: '-1,000.00 USD', balance: '2,350.00 USD' },
      ];

      expect(transactions).toEqual(expected);
    });

    test('Stocks Unconverted', async () => {
      await goto('journal/Assets:Stocks');
      const transactions = await getTransactions();

      const expected = [
        { narration: '', change: '', balance: '' }, // Open
        { narration: 'Buy AAPL', change: '1.00 AAPL', balance: '1.00 AAPL' },
      ];

      expect(transactions).toEqual(expected);
    });

    test('Stocks Converted', async () => {
      await goto('journal/Assets:Stocks?conversion=USD');
      const transactions = await getTransactions();

      const expected = [
        { narration: '', change: '', balance: '' }, // Open
        { narration: 'Buy AAPL', change: '1,000.00 USD', balance: '1,000.00 USD' },
      ];

      expect(transactions).toEqual(expected);
    });
  });

  describe('Static Assets', () => {
    test('static endpoint responds', async () => {
      const response = await fetch(`${SERVER_URL}/static/style.css`);
      expect(response.ok || response.status === 404).toBe(true);
    });
  });
});

async function goto(route) {
  await page.goto(`${SERVER_URL}/${route}`, { waitUntil: 'domcontentloaded' });
  await Bun.sleep(10);
}

async function getTransactions() {
  return await page.evaluate(() => {
    const rows = Array.from(document.querySelectorAll('.journal .row:not(.header)'));
    return rows.map(row => {
      const narrationEl = row.querySelector('.payee-narration .narration');
      const changeEl = row.querySelector('.cell.change');
      const balanceEl = row.querySelector('.balances .balance');

      return {
        narration: narrationEl ? narrationEl.textContent.trim() : '',
        change: changeEl ? changeEl.textContent.trim() : '',
        balance: balanceEl ? balanceEl.textContent.trim() : '',
      };
    });
  });
}
