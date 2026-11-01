# Contributing to WakeOnCue

Thank you for helping. Before your pull request can be merged:

1. **Sign the CLA.** Read [CLA.md](CLA.md) and comment on your pull request:
   "I have read the WakeOnCue CLA (version 1.0) and I hereby sign it."
   You keep the copyright in your work. The CLA lets the maintainer ship
   WakeOnCue on the App Store and offer it under other terms, which the
   AGPL alone does not allow for code written by others.
2. **Know which license your change uses.** Changes under `ios/` are
   AGPL-3.0-only; changes under `server/` and elsewhere are Apache-2.0.
   See [LICENSE](LICENSE).
3. **Only add third-party code or models with compatible licenses**
   (for example MIT, BSD, Apache-2.0), and name the source and license in
   the pull request.
4. **Run the tests** listed in the README for the parts you changed.

## Privacy rules for contributions

Telling speakers apart and remembering voices are off until the user turns
them on, and voiceprints stay on the user's iPhone. Do not add features that
recognize people without that opt-in, upload or sync voiceprints, or send
audio anywhere the user has not configured. See
[docs/realtime-processing.md](docs/realtime-processing.md).

## 中文说明

提交 PR 前请阅读 [CLA.md](CLA.md)，并在 PR 中留言签署。你保留代码的版权；签署 CLA
是为了让维护者能把 WakeOnCue 发布到 App Store，并在需要时以其他条款提供。`ios/`
下的代码使用 AGPL-3.0-only，`server/` 及其他部分使用 Apache-2.0。区分说话人和记住
声音必须保持默认关闭、由用户主动开启，声纹只能留在用户的 iPhone 上。
