require('esbuild')
  .build({
    entryPoints: ['./src/extension.ts'],
    bundle: true,
    outfile: './dist/extension.js',
    external: [
      'vscode',
      'vscode-languageserver-types',
      'vscode-languageserver-protocol',
      'vscode-languageclient',
    ],
    format: 'cjs',
    platform: 'node',
    target: 'es2022',
    sourcemap: 'external',
    minify: process.env.NODE_ENV === 'production',
    loader: {
      '.ts': 'ts',
    },
    resolveExtensions: ['.ts', '.js'],
    tsconfig: './tsconfig.json',
  })
  .then(() => console.log('Build succeeded'))
  .catch((error) => {
    console.error('Build failed:', error);
    process.exit(1);
  });
