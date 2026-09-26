/**
 * The newest app build, which every installed app compares itself against.
 *
 * Bump `build` (the number after `+` in pubspec.yaml's `version`) and
 * `version` whenever a new APK is published as a GitHub release; the app then
 * shows "Update available" to everyone on an older build.
 *
 * The URL always points at the latest GitHub release's `GeoGuard.apk`, so it
 * never has to change as long as each release attaches a file with that name.
 */
export const LATEST_RELEASE = {
  build: 2,
  version: '1.0.1',
  url: 'https://github.com/ShUbHaMHiReMaT/veripic_flutter_app/releases/latest/download/GeoGuard.apk',
  notes: 'Delete photos from the Photos tab.',
};
