import * as assert from 'assert';
import * as vscode from 'vscode';
import { Position, TextDocument, DiagnosticSeverity } from 'vscode';
import * as fs from 'fs/promises';
import * as path from 'path';


suite('LSP', () => {
    let doc: vscode.TextDocument;

    suiteSetup(async function() {
        this.timeout(10000); // Increase timeout for LSP initialization
        const waitPromise = waitForLSPReady();
        doc = await openDoc('main.bean');
        await waitPromise;
    });

    test('Hover on Assets:Checking', async function() {
        const pos = findInLine(doc, 10, 'Assets:Checking');
        await moveTo(doc, pos);
        const hovers = await vscode.commands.executeCommand<vscode.Hover[]>(
            'vscode.executeHoverProvider',
            doc.uri,
            pos
        );
        await assertGolden('hover-assets-checking', formatHover(hovers));
    });

    test('Highlight Assets:Checking', async function() {
        const pos = findInLine(doc, 10, 'Assets:Checking');
        await moveTo(doc, pos);
        const highlights = await vscode.commands.executeCommand<vscode.DocumentHighlight[]>(
            'vscode.executeDocumentHighlights',
            doc.uri,
            pos
        );
        await assertGolden('highlight-assets-checking', formatHighlights(doc, highlights));
    });

    test('Highlight Equity:Ope𝄞ning-Balances', async function() {
        const pos = findInLine(doc, 2, 'Equity:Ope𝄞ning-Balances');
        await moveTo(doc, pos);
        const highlights = await vscode.commands.executeCommand<vscode.DocumentHighlight[]>(
            'vscode.executeDocumentHighlights',
            doc.uri,
            pos
        );
        await assertGolden('highlight-equity-opening-balances', formatHighlights(doc, highlights));
    });

    test('Highlight tag #tag', async function() {
        const pos = findInLine(doc, 9, '#tag');
        await moveTo(doc, pos);
        const highlights = await vscode.commands.executeCommand<vscode.DocumentHighlight[]>(
            'vscode.executeDocumentHighlights',
            doc.uri,
            pos
        );
        await assertGolden('highlight-tag', formatHighlights(doc, highlights));
    });

    test('Highlight link ^mylink', async function() {
        const pos = findInLine(doc, 9, '^mylink');
        await moveTo(doc, pos);
        const highlights = await vscode.commands.executeCommand<vscode.DocumentHighlight[]>(
            'vscode.executeDocumentHighlights',
            doc.uri,
            pos
        );
        await assertGolden('highlight-link', formatHighlights(doc, highlights));
    });

    test('Diagnostics', async function() {
        const diagnostics = vscode.languages.getDiagnostics(doc.uri);
        await assertGolden('diagnostics', formatDiagnostics(doc, diagnostics));
    });

    test('Jump to definition', async function() {
        const pos = findInLine(doc, 10, 'Assets:Checking');
        const result = await vscode.commands.executeCommand<vscode.Location[]>(
            'vscode.executeDefinitionProvider',
            doc.uri,
            pos
        );
        assert.equal(result.length, 1);
        const formatted = await formatJumpToDefinition(result[0]);
        await assertGolden('jump-to-definition', formatted);
    });

    test('Autocomplete links', async function() {
        const result = await vscode.commands.executeCommand<vscode.CompletionList>(
            'vscode.executeCompletionItemProvider',
            doc.uri,
            new Position(0, 1),
            '^'
        );
        assert.ok(result);
        const actual = result.items.map(item => String(item.label));
        const expected = [
            '^link',
            '^link1',
            '^link2',
            '^mylink'
        ];
        assert.deepStrictEqual(actual, expected);
    });

    test('Autocomplete tags', async function() {
        const result = await vscode.commands.executeCommand<vscode.CompletionList>(
            'vscode.executeCompletionItemProvider',
            doc.uri,
            new Position(0, 1),
            '#'
        );
        assert.ok(result);
        const actual = result.items.map(item => String(item.label));
        const expected = [
            '#tag',
            '#tag2'
        ];
        assert.deepStrictEqual(actual, expected);
    });

    test('Inlay hints', async function() {
        this.timeout(5000);
        let hints: vscode.InlayHint[] = [];
        // Retry a few times to allow the LSP to finish processing
        for (let attempt = 0; attempt < 10; attempt++) {
            const range = new vscode.Range(
                new Position(0, 0),
                new Position(doc.lineCount, 0)
            );
            hints = await vscode.commands.executeCommand<vscode.InlayHint[]>(
                'vscode.executeInlayHintProvider',
                doc.uri,
                range
            ) ?? [];
            if (hints.length > 0) { break; }
            await sleep(200);
        }
        assert.ok(hints.length > 0, `Expected at least one inlay hint, got ${hints.length}`);
        await assertGolden('inlay-hints', formatInlayHints(doc, hints));
    });

    test('Autocomplete accounts', async function() {
        const result = await vscode.commands.executeCommand<vscode.CompletionList>(
            'vscode.executeCompletionItemProvider',
            doc.uri,
            new Position(1, 1),
            null
        );
        assert.ok(result);
        const actual = result.items.map(item => String(item.label));
        const expected = [
            'Assets:Checking',
            'Assets:Foo',
            'Assets:Stocks',
            'Equity:Ope𝄞ning-Balances',
            'Expenses:Food'
        ];
        assert.deepStrictEqual(actual, expected);
    });
});


async function sleep(ms: number = 10) {
    return new Promise(resolve => setTimeout(resolve, ms));
}

async function waitForLSPReady(timeoutMs: number = 8000): Promise<void> {
    // Set up the listener before opening the document to catch the diagnostic event
    return new Promise((resolve, reject) => {
        const timeout = setTimeout(() => {
            disposable.dispose();
            reject(new Error('LSP did not initialize within timeout - no diagnostics received'));
        }, timeoutMs);

        // Wait for any diagnostic change event (indicating LSP is active)
        const disposable = vscode.languages.onDidChangeDiagnostics(() => {
            clearTimeout(timeout);
            disposable.dispose();
            resolve();
        });
    });
}

async function openDoc(file: string): Promise<TextDocument> {
    const root = vscode.workspace.workspaceFolders![0].uri;
    const uri = vscode.Uri.joinPath(root, file);
    const doc = await vscode.workspace.openTextDocument(uri);
    await sleep();
    await vscode.window.showTextDocument(doc);
    await sleep();
    return doc;
}

async function moveTo(doc: TextDocument, position: Position) {
    await vscode.window.showTextDocument(doc, { selection: new vscode.Range(position, position) });
    await sleep();
}

/**
 * Find the position of text within a specific line (0-indexed).
 * Returns the position at the start of the found text.
 */
function findInLine(doc: TextDocument, line: number, text: string): Position {
    const lineText = doc.lineAt(line).text;
    const index = lineText.indexOf(text);
    if (index === -1) {
        throw new Error(`Could not find "${text}" in line ${line + 1}: "${lineText}"`);
    }
    return new Position(line, index);
}

// ============================================================================
// Golden Test Infrastructure
// ============================================================================

function formatHighlights(doc: TextDocument, highlights: vscode.DocumentHighlight[]): string {
    // Group highlights by line
    const lineMap = new Map<number, vscode.Range[]>();
    for (const h of highlights) {
        const line = h.range.start.line;
        if (!lineMap.has(line)) {
            lineMap.set(line, []);
        }
        lineMap.get(line)!.push(h.range);
    }

    const result: string[] = [];

    for (let lineNum = 0; lineNum < doc.lineCount; lineNum++) {
        const lineText = doc.lineAt(lineNum).text;
        result.push(lineText);

        // Add underline if this line has highlights
        const ranges = lineMap.get(lineNum);
        if (ranges) {
            // Build underline string
            const underline = new Array(lineText.length).fill(' ');
            for (const range of ranges) {
                for (let j = range.start.character; j < range.end.character; j++) {
                    underline[j] = '-';
                }
            }
            result.push(underline.join('').trimEnd());
        }
    }

    return result.join('\n');
}

function formatDiagnostics(doc: TextDocument, diagnostics: vscode.Diagnostic[]): string {
    if (diagnostics.length === 0) {
        return '(no diagnostics)';
    }

    // Group by line
    const byLine = new Map<number, vscode.Diagnostic[]>();
    for (const d of diagnostics) {
        const line = d.range.start.line;
        if (!byLine.has(line)) {
            byLine.set(line, []);
        }
        byLine.get(line)!.push(d);
    }

    const result: string[] = [];

    for (let lineNum = 0; lineNum < doc.lineCount; lineNum++) {
        const lineText = doc.lineAt(lineNum).text;
        result.push(lineText);

        // Add diagnostics if this line has any
        const diags = byLine.get(lineNum);
        if (diags) {
            for (const d of diags) {
                const arrows = ' '.repeat(d.range.start.character) + '^'.repeat(d.range.end.character - d.range.start.character);
                const severity = d.severity === DiagnosticSeverity.Error ? 'Error' :
                    d.severity === DiagnosticSeverity.Warning ? 'Warn' :
                        d.severity === DiagnosticSeverity.Information ? 'Info' : 'Hint';
                result.push(`${arrows} ${severity}: ${d.message}`);
            }
        }
    }

    return result.join('\n');
}

function formatHover(hovers: vscode.Hover[]): string {
    assert.equal(hovers.length, 1);
    const contents = hovers[0].contents;
    assert.equal(contents.length, 1);
    const c = contents[0];
    const text = typeof c === 'string' ? c : c.value;

    // Undo HTML formatting
    return text.replace(/\n\n/g, '\n').replace(/&nbsp;/g, ' ').trim();
}

async function formatJumpToDefinition(location: vscode.Location): Promise<string> {
    const toFile = location.uri.fsPath.split('/').pop();
    const targetLine = location.range.start.line;

    const targetDoc = await vscode.workspace.openTextDocument(location.uri);

    const result: string[] = [];
    result.push(`${toFile}:${targetLine + 1}:${location.range.start.character}`);
    result.push('');

    // Show entire destination file with marker on target line
    for (let i = 0; i < targetDoc.lineCount; i++) {
        const lineText = targetDoc.lineAt(i).text;
        const prefix = i === targetLine ? '>' : ' ';
        result.push(`${prefix} ${lineText}`);
    }

    return result.join('\n');
}

function formatInlayHints(doc: TextDocument, hints: vscode.InlayHint[]): string {
    // Group hints by line
    const lineMap = new Map<number, vscode.InlayHint[]>();
    for (const h of hints) {
        const line = h.position.line;
        if (!lineMap.has(line)) {
            lineMap.set(line, []);
        }
        lineMap.get(line)!.push(h);
    }

    const result: string[] = [];

    for (let lineNum = 0; lineNum < doc.lineCount; lineNum++) {
        const lineText = doc.lineAt(lineNum).text;
        const lineHints = lineMap.get(lineNum);

        if (!lineHints) {
            result.push(lineText);
            continue;
        }

        // Sort hints by position
        lineHints.sort((a, b) => a.position.character - b.position.character);

        // Build the line with hints inserted, then add underline markers
        let output = '';
        let lastCol = 0;
        const underline = new Array(lineText.length).fill(' ');
        let outputOffset = 0; // tracks how output length diverges from source columns

        for (const hint of lineHints) {
            const col = hint.position.character;
            const before = lineText.substring(lastCol, col);
            output += before;
            outputOffset += before.length - (col - lastCol); // should be 0 for ASCII

            const label = typeof hint.label === 'string' ? hint.label : hint.label.map(p => p.value).join('');
            let hintText = '';
            if (hint.paddingLeft) { hintText += ' '; }
            hintText += label;
            if (hint.paddingRight) { hintText += ' '; }

            const hintStart = output.length;
            output += hintText;
            // Extend underline array to fit
            while (underline.length < output.length + (lineText.length - col)) {
                underline.push(' ');
            }
            for (let j = hintStart; j < hintStart + hintText.length; j++) {
                underline[j] = '^';
            }
            outputOffset += hintText.length;
            lastCol = col;
        }
        const rest = lineText.substring(lastCol);
        output += rest;
        // Shift underline markers for text after last hint
        result.push(output);
        const underlineStr = underline.join('').trimEnd();
        if (underlineStr.length > 0) {
            result.push(underlineStr);
        }
    }

    return result.join('\n');
}

/**
 * Compare actual output with expected golden file.
 * If ACCEPT=true, update the expected file with actual output.
 */
async function assertGolden(testName: string, actual: string) {
    const root = vscode.workspace.workspaceFolders![0].uri.fsPath;
    const expectedPath = path.join(root, 'expected', `${testName}.txt`);

    const acceptMode = process.env.ACCEPT === 'true';

    if (acceptMode) {
        await fs.mkdir(path.dirname(expectedPath), { recursive: true });
        await fs.writeFile(expectedPath, actual, 'utf-8');
        return;
    }

    let expected: string;
    try {
        expected = await fs.readFile(expectedPath, 'utf-8');
    } catch (err) {
        assert.fail(`Expected file not found: ${expectedPath}\n\nRun with ACCEPT=true to create it.\n\nActual output:\n${actual}`);
    }

    const normalizeActual = actual.trim().replace(/\r\n/g, '\n');
    const normalizeExpected = expected.trim().replace(/\r\n/g, '\n');

    assert.equal(normalizeActual, normalizeExpected, `Golden test failed: ${testName}\nRun with ACCEPT=true to update expected output.`);
}
