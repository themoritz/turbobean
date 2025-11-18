# D3 Custom Bundle Generator

This project generates a custom, minified bundle of D3.js containing only the
modules used in `plot.js`.

## Usage

1. Install dependencies:
   ```bash
   bun install
   ```

2. Build the bundle:
   ```bash
   bun run build
   ```

3. The minified bundle will be generated at `dist/d3-custom.iife.js`

4. Move the generated file to `../src/assets/js/d3-custom.iife.js`.

## Output

The build process creates an IIFE (Immediately Invoked Function Expression)
bundle that exposes a global `d3` object with all the required D3
functionality.
