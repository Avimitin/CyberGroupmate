/**
 * paths.ts — 运行时路径解析的唯一真相源。
 *
 * 核心概念:把"只读资源根"和"可写数据根"彻底分开。
 *
 *   - getProjectRoot()  → 只读资源所在目录:`src/`、`node_modules/`、`system-prompts/`。
 *                         开发态 = 源码树根;生产态 = Nix store 里包源码的根。
 *                         基于本模块文件的 `__dirname` 推算,**绝不依赖 cwd**。
 *
 *   - getDataDir()      → 可写数据所在目录:`config.yaml`、`workspace/`、
 *                         `workspace/memory.db`、`workspace/tg-session/`、
 *                         `workspace/skills/` 等全部在这里。
 *                         = `process.cwd()`。开发态 cwd 就是源码树根,所以数据
 *                         仍落在源码树(向后兼容);生产态 cwd 是包 wrapper 切过去的
 *                         数据目录(Nix 包里默认 `$HOME/.local/share/cybergroupmate`,
 *                         可被 `CYBERGROUPMATE_WORKDIR` 覆盖),因此数据落在可写位置。
 *
 * 规则:凡是读/写 `workspace/`、`config.yaml` 的代码,**必须**走 `getDataDir()`,
 *       **绝不**用 `getProjectRoot()`。`getProjectRoot()` 只用于定位只读资源。
 */

import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

let _projectRoot: string | null = null;

/**
 * 只读资源根。基于本文件位置推算(`src/core/` → 上两级 = 项目根)。
 * 在 tsx 直跑源码和打包成产物两种形态下都能正确指向 `src/` / `node_modules/` /
 * `system-prompts/` 所在目录。
 */
export function getProjectRoot(): string {
    if (_projectRoot) return _projectRoot;
    try {
        const thisFile = fileURLToPath(import.meta.url);
        _projectRoot = join(dirname(thisFile), "..", "..");
    } catch {
        // 兜底:极端情况下(无法解析 import.meta)退回 cwd。仅在裸跑、无打包
        // 上下文时出现,此时 cwd 通常就是源码树根,语义等价。
        _projectRoot = process.cwd();
    }
    return _projectRoot;
}

/**
 * 可写数据根。所有 `workspace/*`、`config.yaml` 都挂在这里。
 * 直接使用 `process.cwd()`:包的入口 wrapper 已把 cwd 切到数据目录。
 *
 * 注意:**不要**在此函数里再做 `join(process.cwd(), "workspace")` 之类的拼接——
 * 让调用方按需拼 `workspace/xxx`,保持单一职责。
 */
export function getDataDir(): string {
    return process.cwd();
}

/** `workspace/` 目录的绝对路径(等价于 `join(getDataDir(), "workspace")`)。 */
export function getWorkspaceDir(): string {
    return join(getDataDir(), "workspace");
}

/** 只读资源根下的路径拼接便捷函数(等价于 `join(getProjectRoot(), ...rel)`)。 */
export function projectPath(...rel: string[]): string {
    return join(getProjectRoot(), ...rel);
}

/** 可写数据根下的路径拼接便捷函数(等价于 `join(getDataDir(), ...rel)`)。 */
export function dataPath(...rel: string[]): string {
    return join(getDataDir(), ...rel);
}
