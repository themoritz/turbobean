# TurboBean Puppeteer Integration Tests

This directory contains Puppeteer-based integration tests for the turbobean web server.

## Prerequisites

- [Bun](https://bun.sh/) runtime installed

## Installation

Install dependencies using Bun:

```bash
cd tests
bun install
```

## Running Tests

### Run all tests (headless mode):

```bash
bun test
```

### Run tests with visible browser (headful mode):

```bash
bun run test:headful
```
