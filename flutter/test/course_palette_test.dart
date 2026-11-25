import 'package:course_planner/core/theme/course_palette.dart';
import 'package:course_planner/domain/course.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _hexPattern = r'^#[0-9A-F]{6}$';

Course _course(String id) => Course(
  id: id,
  calendarId: 'cal1',
  name: '课程 $id',
  revision: 0,
);

void main() {
  group('assignColorsForCourses', () {
    test('gives 12 courses unique colours at least 10 ΔE apart', () {
      final courses = [for (var i = 0; i < 12; i++) _course('c$i')];
      final colors = CoursePalette.assignColorsForCourses(courses);

      expect(colors.keys, unorderedEquals(courses.map((c) => c.id)));
      final hexes = colors.values.toList();
      expect(hexes.toSet(), hasLength(12));

      for (var i = 0; i < hexes.length; i++) {
        for (var j = i + 1; j < hexes.length; j++) {
          expect(
            CoursePalette.distance(hexes[i], hexes[j]),
            greaterThanOrEqualTo(10.0),
            reason: '${hexes[i]} and ${hexes[j]} are too close',
          );
        }
      }
    });

    test('every style emits valid #RRGGBB colours, even past the pool size', () {
      final courses = [for (var i = 0; i < 20; i++) _course('c$i')];
      for (final style in CoursePaletteStyle.values) {
        final colors = CoursePalette.assignColorsForCourses(
          courses,
          style: style,
        );
        expect(colors, hasLength(20), reason: 'style $style');
        expect(colors.values.toSet(), hasLength(20), reason: 'style $style');
        for (final hex in colors.values) {
          expect(hex, matches(_hexPattern), reason: 'style $style -> $hex');
        }
      }
    });

    test('20 courses stay distinguishable in every style', () {
      final courses = [for (var i = 0; i < 20; i++) _course('c$i')];
      for (final style in CoursePaletteStyle.values) {
        final hexes = CoursePalette.assignColorsForCourses(
          courses,
          style: style,
        ).values.toList();
        for (var i = 0; i < hexes.length; i++) {
          for (var j = i + 1; j < hexes.length; j++) {
            final deltaE = CoursePalette.distance(hexes[i], hexes[j]);
            final rawHue =
                (CoursePalette.hueOf(hexes[i]) - CoursePalette.hueOf(hexes[j]))
                    .abs() %
                360;
            final deltaHue = rawHue > 180 ? 360 - rawHue : rawHue;
            expect(
              deltaE >= 10 || deltaHue >= 15,
              isTrue,
              reason:
                  '$style: ${hexes[i]} vs ${hexes[j]} '
                  'ΔE=$deltaE Δh=$deltaHue',
            );
          }
        }
      }
    });

    test('monetHarmony keeps hues in range and distinct for a seed', () {
      const seed = Color(0xFF3F51B5);
      final courses = [for (var i = 0; i < 12; i++) _course('c$i')];
      final colors = CoursePalette.assignColorsForCourses(
        courses,
        style: CoursePaletteStyle.monetHarmony,
        themeSeed: seed,
      );

      final hues = colors.values.map(CoursePalette.hueOf).toList();
      for (final hue in hues) {
        expect(hue, inInclusiveRange(0, 360));
        expect(hue, lessThan(360));
      }
      expect(hues.map((h) => h.round()).toSet(), hasLength(hues.length));
    });
  });

  group('pickDistinctColor', () {
    test('avoids colours that are already in use', () {
      final courses = [for (var i = 0; i < 4; i++) _course('c$i')];
      final assigned = CoursePalette.assignColorsForCourses(courses)
          .values
          .toList();

      // None of the assigned colours may come back, even though the pool is
      // larger than the set that is already in use.
      final next = CoursePalette.pickDistinctColor(assigned);
      expect(assigned, isNot(contains(next)));

      // A single occupied colour is avoided too.
      expect(
        CoursePalette.pickDistinctColor([assigned.first]),
        isNot(assigned.first),
      );
    });

    test('tolerates empty, null and malformed input', () {
      expect(CoursePalette.pickDistinctColor(const []), matches(_hexPattern));
      expect(
        CoursePalette.pickDistinctColor(const [null, '', '#12', 'zzzzzz', '#GGGGGG']),
        matches(_hexPattern),
      );
      expect(
        CoursePalette.pickDistinctColor(
          const ['#8F70C2'],
          style: CoursePaletteStyle.vibrant,
        ),
        matches(_hexPattern),
      );
      expect(CoursePalette.distance('not-a-colour', '#8F70C2'), 0);
      expect(CoursePalette.hueOf('nope'), 0);
      expect(
        CoursePalette.assignColorsForCourses(const []),
        isEmpty,
      );
    });

    test('a seeded monet palette is stable and still avoids duplicates', () {
      const seed = Color(0xFF26A69A);
      final first = CoursePalette.pickDistinctColor(
        const [],
        style: CoursePaletteStyle.monetHarmony,
        themeSeed: seed,
      );
      final again = CoursePalette.pickDistinctColor(
        const [],
        style: CoursePaletteStyle.monetHarmony,
        themeSeed: seed,
      );
      expect(again, first);
      final second = CoursePalette.pickDistinctColor(
        [first],
        style: CoursePaletteStyle.monetHarmony,
        themeSeed: seed,
      );
      expect(second, isNot(first));
    });
  });
}
