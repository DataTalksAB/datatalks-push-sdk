# Releasing

All SDKs share one version, and one tag releases them all. The tag is the plain semantic version, for example
`0.5.0-beta.1`, because Swift Package Manager only reads tags of that form.

| SDK | Published to | By |
|---|---|---|
| Android | Maven Central, `se.datatalks:push-android` | `android.yml` |
| iOS | Swift Package Manager, from the tag itself | no upload; `ios.yml` checks the versions |
| .NET MAUI | nuget.org, `DataTalks.Push.Maui` and its two bindings | `maui.yml` |
| Capacitor | npm, `@datatalks-ab/push-capacitor` | `capacitor.yml` |
| All | A GitHub release with the changelog section | `release.yml` |

## Releasing a version

1. Set the version in every SDK and check it:
   - `sdks/android/gradle.properties` (`version`)
   - `sdks/ios/Sources/DataTalksPush/AppKeys.swift` (`version`) and
     `sdks/ios/Sources/DataTalksPushExtension/DeliveryReporter.swift` (`sdkHeader`)
   - `sdks/maui/Directory.Build.props` (`Version`)
   - `sdks/capacitor/package.json` and `package-lock.json` (`version`), and `sdks/capacitor/android/build.gradle`
     (`dataTalksPushVersion`)

   ```bash
   tools/release/check-version.sh 0.5.0-beta.1
   ```

2. Add a `## <version>` section to `CHANGELOG.md`.
3. Merge to `main` and wait for the workflows to pass.
4. Tag `main` and push the tag:

   ```bash
   git tag 0.5.0-beta.1
   git push origin 0.5.0-beta.1
   ```

Each publishing job checks the versions against the tag first and stops on a mismatch. A version with a pre-release
suffix (`-beta.1`) is published as a pre-release: npm's `beta` tag and a GitHub pre-release.

Maven Central, nuget.org and npm never take a version back, so approve the publish jobs (environment `release`) only
once every workflow of the tag has passed its tests. `release.yml` creates the GitHub release as a draft: publish it
last, when the packages are out.

## One-time set-up

### GitHub

- The repository is `DataTalksTeam/datatalks-push-sdk`, with exactly that casing: the Maven POM, `package.json` and the
  MAUI packages point to it. It must be public before the first release tag, because npm provenance needs a public
  repository.
- Create an environment named `release` (Settings → Environments) and add required reviewers to approve each publish.
  The publishing jobs read their secrets from it. If you limit its deployments, choose "Selected branches and tags" and
  allow the tag pattern `[0-9]*.[0-9]*.[0-9]*`.
- Add a tag ruleset for the same pattern, so that only maintainers can create release tags.
- Don't mark the SDK workflows as required status checks: they run only when their files change, so a skipped workflow
  would leave the check pending.

### Maven Central (Android)

1. Sign in to [central.sonatype.com](https://central.sonatype.com) and register the namespace `se.datatalks`. Verify it
   with the DNS TXT record the portal gives you, on `datatalks.se`.
2. Generate a user token (View Account → Generate User Token).
3. Create a GPG key for signing and publish its public part to a key server, for example `keys.openpgp.org`.
4. Add the environment secrets:
   - `MAVEN_CENTRAL_USERNAME`, `MAVEN_CENTRAL_PASSWORD`: the user token's two parts;
   - `SIGNING_KEY`: the ASCII-armored private key (`gpg --armor --export-secret-keys <key id>`);
   - `SIGNING_KEY_PASSWORD`: its passphrase.

### nuget.org (.NET MAUI)

1. On nuget.org, open Trusted Publishing and add a policy: repository owner and name, workflow file `maui.yml`,
   environment `release`.
2. Add the environment secret `NUGET_USER`: the nuget.org user name (not the email).

Optionally reserve the `DataTalks.` package id prefix.

### npm (Capacitor)

1. Create the npm organization `datatalks-ab`.
2. A trusted publisher is configured on an existing package, so the first version goes out with a token: create a
   granular access token that can publish to the `@datatalks-ab` scope (with the option to bypass two-factor
   authentication, if the organization requires it), and add it as the environment secret `NPM_TOKEN`.
3. After the first release, add the trusted publisher on the package's settings page: repository owner and name,
   workflow file `capacitor.yml`, environment `release`. Then delete the `NPM_TOKEN` secret and revoke the token.
