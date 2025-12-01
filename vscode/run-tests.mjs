#!/usr/bin/env node
import { spawn } from 'child_process';
import { readFile } from 'fs/promises';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';

const __dirname = dirname(fileURLToPath(import.meta.url));
const logFilePath = join(__dirname, '..', 'turbobean-vscode.log');

// Set environment variable to indicate test mode
process.env.VSCODE_TURBOBEAN_TEST = 'true';

// Run vscode-test
const testProcess = spawn('npx', ['vscode-test'], {
    stdio: 'inherit',
    env: process.env,
    shell: true
});

testProcess.on('exit', async (code) => {
    if (code !== 0) {
        // Test failed, print the log file
        console.error('\n\n==================== TurboBean LSP Log ====================');
        try {
            const logContent = await readFile(logFilePath, 'utf-8');
            console.error(logContent);
        } catch (err) {
            console.error(`Failed to read log file at ${logFilePath}: ${err.message}`);
        }
        console.error('===========================================================\n');
    }
    process.exit(code);
});

testProcess.on('error', (err) => {
    console.error('Failed to start test process:', err);
    process.exit(1);
});
