import 'package:delta_view/diff/structured/csv.dart';
import 'package:delta_view/diff/structured/structured_compare.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseCsv', () {
    test('quotes, doubled quotes, delimiters and newlines in fields', () {
      expect(
        parseCsv('id,text\n1,"a, b"\n2,"say ""hi"""\n3,"two\nlines"\n'),
        [
          ['id', 'text'],
          ['1', 'a, b'],
          ['2', 'say "hi"'],
          ['3', 'two\nlines'],
        ],
      );
    });

    test('any line ending, empty fields, blank lines skipped', () {
      expect(parseCsv('a,b,\r\n\r\n,x,\r"q",\n'), [
        ['a', 'b', ''],
        ['', 'x', ''],
        ['q', ''],
      ]);
      expect(parseCsv(''), isEmpty);
    });

    test('a quote inside an unquoted field is just a character', () {
      expect(parseCsv('5" pipe,ok'), [
        ['5" pipe', 'ok'],
      ]);
    });

    test('an unclosed quote is an error where it opened', () {
      expect(
        () => parseCsv('a,b\n1,"oops\n2,3\n'),
        throwsA(isA<CsvParseException>()
            .having((e) => e.line, 'line', 2)
            .having((e) => e.column, 'column', 3)),
      );
    });

    test('tabs, and sniffing the delimiter', () {
      expect(parseCsv('a\tb\n1\t2', delimiter: '\t'), [
        ['a', 'b'],
        ['1', '2'],
      ]);
      expect(sniffDelimiter('a;b;c\n1;2;3'), ';');
      expect(sniffDelimiter('"x;y",b,c'), ',');
      expect(sniffDelimiter('single'), ',');
      expect(parseTable('id;name\n1;Ann\n', StructuredFormat.csv), [
        ['id', 'name'],
        ['1', 'Ann'],
      ]);
    });
  });

  group('diffTables', () {
    final left = parseCsv('id,name,city\n1,Ann,Paris\n2,Bob,Berlin\n'
        '3,Cy,Rome\n');
    final right = parseCsv('id,name,city\n2,Bob,Bonn\n1,Ann,Paris\n'
        '4,Dee,Oslo\n');

    test('matches rows by the key column, whatever their order', () {
      final d = diffTables(left, right);
      expect(d.columns, ['id', 'name', 'city']);
      expect([
        for (final r in d.rows) (r.key, r.status)
      ], [
        ('2', RowStatus.changed),
        // Removed rows follow the row they came after on the left.
        ('3', RowStatus.removed),
        ('1', RowStatus.same),
        ('4', RowStatus.added),
      ]);
      final bob = d.rows.first;
      expect(bob.changedColumns, {2});
      expect((bob.left[2], bob.right[2]), ('Berlin', 'Bonn'));
      expect((bob.leftRow, bob.rightRow), (3, 2));
      expect(d.count(RowStatus.changed), 1);
      expect(d.changedCells, 1);
    });

    test('another key column', () {
      final d =
          diffTables(left, right, const TableDiffOptions(keyColumn: 2)); // city
      // Berlin and Rome left, Bonn and Oslo arrived; Paris stays.
      expect(d.count(RowStatus.same), 1);
      expect(d.count(RowStatus.removed), 2);
      expect(d.count(RowStatus.added), 2);
    });

    test('columns match by header name, so moved columns are not changes', () {
      final d = diffTables(
        parseCsv('id,a,b\n1,x,y\n'),
        parseCsv('b,id,a,c\ny,1,x,new\n'),
      );
      expect(d.columns, ['id', 'a', 'b', 'c']);
      expect(d.columnStatus, [
        ColumnStatus.same,
        ColumnStatus.same,
        ColumnStatus.same,
        ColumnStatus.added,
      ]);
      expect(d.rows.single.status, RowStatus.same);
      expect(d.rows.single.right, ['1', 'x', 'y', 'new']);
    });

    test('without a header, columns go by position', () {
      final d = diffTables(
        parseCsv('1,a\n2,b\n'),
        parseCsv('2,B\n1,a\n3,c,extra\n'),
        const TableDiffOptions(header: false),
      );
      expect(d.columns, ['Column 1', 'Column 2', 'Column 3']);
      expect(d.columnStatus.last, ColumnStatus.added);
      expect([for (final r in d.rows) r.status],
          [RowStatus.changed, RowStatus.same, RowStatus.added]);
    });

    test('repeated keys match in order of appearance', () {
      final d = diffTables(
        parseCsv('k,v\na,1\na,2\n'),
        parseCsv('k,v\na,1\na,3\na,4\n'),
      );
      expect([for (final r in d.rows) r.status],
          [RowStatus.same, RowStatus.changed, RowStatus.added]);
    });

    test('ragged rows and a missing file', () {
      final ragged = diffTables(parseCsv('a,b\n1\n'), parseCsv('a,b\n1,\n'));
      expect(ragged.rows.single.status, RowStatus.same);
      final missing = diffTables(null, parseCsv('a\n1\n2\n'));
      expect(missing.count(RowStatus.added), 2);
    });

    test('large tables match quickly', () {
      final rows = [
        ['id', 'v'],
        for (var i = 0; i < 100000; i++) ['$i', 'v$i'],
      ];
      final shuffled = [
        rows.first,
        ...rows.sublist(1).reversed,
      ];
      shuffled[500] = ['x', 'changed'];
      final sw = Stopwatch()..start();
      final d = diffTables(rows, shuffled);
      expect(sw.elapsedMilliseconds, lessThan(3000));
      expect(d.count(RowStatus.added), 1);
      expect(d.count(RowStatus.removed), 1);
    });
  });
}
