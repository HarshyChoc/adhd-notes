export function positionAtLogicalColumn(doc, lineNumber, column) {
  const boundedLineNumber = Math.max(1, Math.min(lineNumber, doc.lines));
  const line = doc.line(boundedLineNumber);
  return Math.min(line.from + Math.max(0, column), line.to);
}

export function verticalNavigationTarget(doc, head, direction, block) {
  if (direction !== -1 && direction !== 1) {
    throw new RangeError('direction must be -1 or 1');
  }

  if ((direction < 0 && head === 0) || (direction > 0 && head === doc.length)) {
    return { handled: true, target: head };
  }

  if (!block) return { handled: false, target: head };

  const currentLine = doc.lineAt(head);
  const column = head - currentLine.from;
  if (block.kind === 'table') {
    return {
      handled: true,
      target: positionAtLogicalColumn(doc, currentLine.number + direction, column),
    };
  }

  const firstBlockLine = doc.lineAt(block.from).number;
  const lastBlockLine = doc.lineAt(Math.max(block.from, block.to - 1)).number;
  const destinationLine = direction > 0 ? lastBlockLine + 1 : firstBlockLine - 1;
  if (destinationLine < 1) return { handled: true, target: 0 };
  if (destinationLine > doc.lines) return { handled: true, target: doc.length };
  return {
    handled: true,
    target: positionAtLogicalColumn(doc, destinationLine, column),
  };
}
