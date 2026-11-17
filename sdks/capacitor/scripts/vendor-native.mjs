// Copies the native SDKs from this repository into the package: the iOS sources that the pod and the Swift package compile,
// and the Android SDK as a local Maven repository. Run it before packing, and after changing either SDK when an app installs
// this folder. The Android step needs Java 17 or later (JAVA_HOME).
import { execSync } from 'node:child_process';
import { cpSync, readFileSync, rmSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const plugin = join(dirname(fileURLToPath(import.meta.url)), '..');
const repository = join(plugin, '..');

// The plugin's build.gradle names the SDK version it depends on; gradle.properties sets the version published below. A
// mismatch would only fail later, when the app's build resolves the dependency, so stop here instead.
const published = readFileSync(join(repository, 'android', 'gradle.properties'), 'utf8').match(/^version=(.+)$/m)?.[1].trim();
const wanted = readFileSync(join(plugin, 'android', 'build.gradle'), 'utf8').match(/dataTalksPushVersion = '([^']+)'/)?.[1];
if (!published || published !== wanted) {
  console.error(`android/build.gradle wants push-android ${wanted}, but android/gradle.properties publishes ${published}. Make them match.`);
  process.exit(1);
}

const iosCore = join(plugin, 'ios', 'Sources', 'DataTalksPushPlugin', 'Core');
rmSync(iosCore, { recursive: true, force: true });
cpSync(join(repository, 'ios', 'Sources', 'DataTalksPush'), iosCore, { recursive: true });
console.log(`iOS SDK sources copied to ${iosCore}`);

// The notification service extension's sources go outside ios/Sources so the plugin's pod never compiles them. The
// extension's own pod and Swift package product (DataTalksPushExtension) build them without Capacitor.
const iosExtension = join(plugin, 'ios', 'Extension');
rmSync(iosExtension, { recursive: true, force: true });
cpSync(join(repository, 'ios', 'Sources', 'DataTalksPushExtension'), iosExtension, { recursive: true });
console.log(`iOS extension sources copied to ${iosExtension}`);

rmSync(join(plugin, 'android', 'maven'), { recursive: true, force: true });
const android = join(repository, 'android');
// A full, quoted path: a shell may not look in the working directory for commands, and the path can contain spaces. A single
// fixed command line, because Node runs a .bat only through a shell.
const gradlew = join(android, process.platform === 'win32' ? 'gradlew.bat' : 'gradlew');
execSync(`"${gradlew}" :push:publishMavenPublicationToCapacitorRepository --console=plain -q`, { cwd: android, stdio: 'inherit' });
console.log(`Android SDK published to ${join(plugin, 'android', 'maven')}`);
