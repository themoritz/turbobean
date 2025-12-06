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
let sseInterceptionSetup = false;

beforeAll(async () => {
  console.log('Starting turbobean server...');
  await new Promise((resolve, reject) => {
    server = spawn(BINARY_PATH, ['serve', TEST_FILE], {
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
    test('Plot points (week, unconverted)', async () => {
      const sseCapture = await captureSSEEvents('plot_points');
      await goto('balance_sheet?interval=week');

      const events = await sseCapture.waitForEvents(1);
      expect(events.length).toBe(1);

      const plotPoints = events[0].data;

      const expected = [
        { date: '2024-01-07', currency: 'USD', balance: 1000.0, balance_rendered: '1,000.00' },
        { date: '2024-01-14', currency: 'USD', balance: 1000.0, balance_rendered: '1,000.00' },
        { date: '2024-01-21', currency: 'USD', balance: 3850.0, balance_rendered: '3,850.00' },
        { date: '2024-01-28', currency: 'AAPL', balance: 1.0, balance_rendered: '1.00' },
        { date: '2024-01-28', currency: 'USD', balance: 2850.0, balance_rendered: '2,850.00' },
      ];

      expect(plotPoints).toEqual(expected);
    });

    test('Plot points (month, converted)', async () => {
      const sseCapture = await captureSSEEvents('plot_points');
      await goto('balance_sheet?conversion=USD&interval=month');

      const events = await sseCapture.waitForEvents(1);
      expect(events.length).toBe(1);

      const plotPoints = events[0].data;

      const expected = [
        { date: '2024-01-31', currency: 'USD', balance: 4850.0, balance_rendered: '4,850.00' },
      ];

      expect(plotPoints).toEqual(expected);
    });
  });

  describe('Income Statement', () => {
    test('Plot points (week)', async () => {
      const sseCapture = await captureSSEEvents('plot_changes');
      await goto('income_statement?interval=week');

      const events = await sseCapture.waitForEvents(1);
      expect(events.length).toBe(1);

      const periods = events[0].data;

      const expected = [
        {
          date: "2024-01-07",
          period: "W1 2024",
          data_points: [],
        },
        {
          date: "2024-01-14",
          period: "W2 2024",
          data_points: [],
        },
        {
          date: "2024-01-21",
          period: "W3 2024",
          data_points: [
            {
              account: "Income:Salary",
              balance: -3000,
              balance_rendered: "-3,000.00",
              currency: "USD",
            },
            {
              account: "Expenses:Groceries",
              balance: 150,
              balance_rendered: "150.00",
              currency: "USD",
            },
          ],
        },
        {
          date: "2024-01-28",
          period: "W4 2024",
          data_points: [],
        },
      ]

      expect(periods).toEqual(expected);
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
  await Bun.sleep(50);
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

async function captureSSEEvents(eventType) {
  // Only set up the interception once
  if (!sseInterceptionSetup) {
    await page.evaluateOnNewDocument(() => {
      // Override EventSource to intercept events
      const OriginalEventSource = window.EventSource;
      window.EventSource = function(...args) {
        // Clear events when a new EventSource is created
        window.__capturedSSEEvents = [];

        const eventSource = new OriginalEventSource(...args);

        // Capture all message events
        eventSource.addEventListener('message', (event) => {
          try {
            window.__capturedSSEEvents.push({
              type: event.type,
              data: JSON.parse(event.data),
              timestamp: Date.now()
            });
          } catch (e) {
            // Silently ignore non-JSON events
          }
        });

        // Also capture named events (like 'plot_points', 'plot_changes', etc.)
        const originalAddEventListener = eventSource.addEventListener.bind(eventSource);
        eventSource.addEventListener = function(type, listener, options) {
          if (type !== 'message' && type !== 'error' && type !== 'open') {
            // Intercept named SSE events
            originalAddEventListener(type, (event) => {
              try {
                window.__capturedSSEEvents.push({
                  type: event.type,
                  data: JSON.parse(event.data),
                  timestamp: Date.now()
                });
              } catch (e) {
                // Silently ignore non-JSON events
              }
              // Still call the original listener
              listener(event);
            }, options);
          } else {
            originalAddEventListener(type, listener, options);
          }
        };

        return eventSource;
      };
    });
    sseInterceptionSetup = true;
  }

  // Clear events from previous tests
  try {
    await page.evaluate(() => {
      window.__capturedSSEEvents = [];
    });
  } catch (e) {
    // Page might not be loaded yet, ignore
  }

  return {
    async waitForEvents(minCount = 1, timeout = 100) {
      const startTime = Date.now();
      while (Date.now() - startTime < timeout) {
        const allEvents = await page.evaluate(() => window.__capturedSSEEvents || []);
        // Filter by event type
        const events = allEvents.filter(e => e.type === eventType);
        if (events.length >= minCount) {
          return events;
        }
        await Bun.sleep(2000);
      }
      throw new Error(`Timeout waiting for ${minCount} SSE events of type "${eventType}"`);
    },
  };
}
