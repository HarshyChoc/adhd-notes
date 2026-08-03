import test from 'node:test';
import assert from 'node:assert/strict';
import { Text } from '@codemirror/state';
import { verticalNavigationTarget } from '../src/vertical-navigation.js';

function doc(value) {
  return Text.of(value.split('\n'));
}

test('repeated arrows stay at the beginning and end of the note', () => {
  const value = doc('first\nlast');
  assert.deepEqual(verticalNavigationTarget(value, 0, -1, null), { handled: true, target: 0 });
  assert.deepEqual(
    verticalNavigationTarget(value, value.length, 1, null),
    { handled: true, target: value.length },
  );
});

test('crossing rendered block math preserves a valid logical column', () => {
  const value = doc('above\n$$\nx + y\n$$\nafter');
  const block = { kind: 'math', from: 6, to: 18 };
  const down = verticalNavigationTarget(value, 3, 1, block);
  assert.equal(down.handled, true);
  assert.equal(down.target, value.line(5).from + 3);

  const up = verticalNavigationTarget(value, value.line(5).from + 4, -1, block);
  assert.equal(up.target, 4);
});

test('table traversal stays on the adjacent logical row and clamps short rows', () => {
  const value = doc('| long heading |\n| --- |\n| x |\nafter');
  const table = { kind: 'table', from: 0, to: value.line(3).to };
  const secondRow = verticalNavigationTarget(value, 12, 1, table);
  assert.equal(secondRow.target, value.line(2).to);

  const thirdRow = verticalNavigationTarget(value, value.line(2).from + 2, 1, table);
  assert.equal(thirdRow.target, value.line(3).from + 2);
});
