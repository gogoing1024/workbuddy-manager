'use client';

import {useMemo, useRef, useState} from 'react';
import {Check, Loader2, Minus, ScanSearch, TriangleAlert} from 'lucide-react';
import {Button} from '@/components/ui/button';
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/animate-ui/radix/dialog';
import {useAsyncAll} from '@/lib/use-async-data';
import {accountApi, errText, modelApi} from '@/lib/api';
import {useI18n} from '@/lib/i18n/provider';
import {planProbeBatches} from '@/lib/probe-batches';
import type {Realm} from '@/lib/realm-context';
import type {
  Account,
  ProbeModelResult,
  ProbeModelsResponse,
  ProbeStatus,
} from '@/lib/types';

const STATUS_KEY: Record<ProbeStatus, string> = {
  ok: 'accounts.probeStatusOk',
  rate: 'accounts.probeStatusRate',
  credit: 'accounts.probeStatusCredit',
  auth: 'accounts.probeStatusAuth',
  no_model: 'accounts.probeStatusNoModel',
  error: 'accounts.probeStatusError',
};

const STATUS_STYLE: Record<ProbeStatus, string> = {
  ok: 'bg-emerald-500/12 text-emerald-700 dark:text-emerald-300 border border-emerald-500/25',
  rate: 'bg-amber-500/12 text-amber-700 dark:text-amber-300 border border-amber-500/25',
  credit: 'bg-orange-500/12 text-orange-700 dark:text-orange-300 border border-orange-500/25',
  auth: 'bg-red-500/12 text-red-700 dark:text-red-300 border border-red-500/25',
  no_model: 'bg-muted text-muted-foreground border border-border',
  error: 'bg-red-500/12 text-red-700 dark:text-red-300 border border-red-500/25',
};

const STATUS_ORDER: ProbeStatus[] = ['ok', 'rate', 'credit', 'auth', 'no_model', 'error'];

/**
 * 账号 × 模型主动探测（issue #270）。
 *
 * 解决的问题：面板此前只能**被动**知道「某号某模型被限流」——要等上游真的拒绝
 * 过一次。新号接入、上游新增模型、遇到 `503 no_healthy_account` 时，都无法回答
 * 「这个号到底能不能用这个模型」。
 *
 * 探测会发**真实请求**（max_tokens=1 的最小对话），所以：
 *   · 账号内串行、每条间隔 600ms，账号间最多 4 路并发（后端实现）；
 *   · 每批最多 60 条组合，界面先显示总请求数、批次数与进度；
 *   · `11102 无此模型` 不算错误——账号本身没问题。
 */
export function ModelProbeDialog({
  open,
  onOpenChange,
  accounts,
  upstreamId,
  realm,
  onFinished,
}: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  /** 当前版本的账号（父组件已按 realm 过滤） */
  accounts: Account[];
  upstreamId: number | null;
  realm: Realm;
  onFinished?: () => void;
}) {
  const {t} = useI18n();
  const [pickedAccounts, setPickedAccounts] = useState<string[]>(
    () => accounts.map((a) => a.file),
  );
  const [pickedModels, setPickedModels] = useState<string[]>([]);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [result, setResult] = useState<ProbeModelsResponse | null>(null);
  const [completed, setCompleted] = useState(0);
  const [stopping, setStopping] = useState(false);
  const stopRequested = useRef(false);

  const catalog = useAsyncAll({catalog: () => modelApi.catalog(realm)}, [realm]);
  const models = catalog.values.catalog?.models ?? [];
  const modelName = (id: string) => models.find((m) => m.id === id)?.name || id;

  const combos = pickedAccounts.length * pickedModels.length;
  const batches = planProbeBatches(pickedAccounts, pickedModels);

  const matrix = useMemo(() => {
    const map = new Map<string, ProbeModelResult>();
    for (const r of result?.results ?? []) {
      map.set(`${r.file}\u0000${r.model}`, r);
    }
    return map;
  }, [result]);

  function toggle(list: string[], value: string): string[] {
    if (list.includes(value)) return list.filter((v) => v !== value);
    return [...list, value];
  }

  async function run() {
    setBusy(true);
    setError('');
    setResult(null);
    setCompleted(0);
    setStopping(false);
    stopRequested.current = false;
    const merged: ProbeModelsResponse = {
      results: [], summary: {ok: 0, rate: 0, credit: 0, auth: 0, no_model: 0, error: 0}, requests: 0,
    };
    try {
      for (const batch of batches) {
        if (stopRequested.current) break;
        const r = await accountApi.probeModels(batch.accounts, batch.models, upstreamId);
        merged.results.push(...r.results);
        merged.requests += r.requests;
        for (const status of STATUS_ORDER) merged.summary[status] += r.summary[status] ?? 0;
        setResult({...merged, results: [...merged.results], summary: {...merged.summary}});
        setCompleted(merged.requests);
        onFinished?.();
      }
    } catch (e) {
      setError(errText(e));
    } finally {
      setBusy(false);
      setStopping(false);
    }
  }

  const canRun = !busy && pickedAccounts.length > 0 && pickedModels.length > 0;

  /** 快捷勾选：把「11102 无此模型」的受限账号与模型一次性选出来。 */
  function selectRestricted() {
    const restricted = accounts.filter((a) =>
      (a.rate_limited_models ?? []).some((m) => m.reason?.startsWith('11102')),
    );
    setPickedAccounts(restricted.map((a) => a.file));
    setPickedModels([...new Set(restricted.flatMap((a) =>
      (a.rate_limited_models ?? [])
        .filter((m) => m.reason?.startsWith('11102'))
        .map((m) => m.model),
    ))]);
  }

  return (
    <Dialog open={open} onOpenChange={(v) => { if (!busy) onOpenChange(v); }}>
      {/* 结果表格出现/隐藏会让弹窗内容高度大幅变化，3D 翻转动画完成后的
          perspective 矩阵在高度重排时会让 Chromium 把子元素绘制到容器外
          （getBoundingClientRect 报负 y），表现为「选最后一个模型后白屏」。
          disableFlip 关闭 3D 翻转、降级为纯淡入淡出，绕开该合成 bug。 */}
      <DialogContent className="max-w-[820px]" disableFlip>
        <DialogHeader className="border-b border-border/50">
          <DialogTitle className="flex items-center gap-2.5">
            <span className="flex size-7 items-center justify-center rounded-lg bg-primary/10 text-primary">
              <ScanSearch className="size-4" />
            </span>
            {t('accounts.probeTitle')}
          </DialogTitle>
          <DialogDescription className="pt-1 text-[12px] leading-relaxed">
            {t('accounts.probeDesc')}
          </DialogDescription>
        </DialogHeader>

        <div className="max-h-[min(560px,calc(100dvh-14rem))] overflow-y-auto">
          <div className="space-y-4 px-6 py-4">
            <div className="grid gap-4 sm:grid-cols-2">
              {/* 账号 */}
              <div className="rounded-xl border border-border/60 bg-muted/30 p-3">
                <div className="mb-2 flex items-center justify-between">
                  <span className="flex items-center gap-1.5 text-xs font-semibold text-foreground/90">
                    {t('accounts.probeAccounts')}
                    <span className="rounded-full bg-primary/10 px-1.5 py-0.5 text-[10px] font-medium tabular-nums text-primary">
                      {pickedAccounts.length}/{accounts.length}
                    </span>
                  </span>
                  <button
                    type="button"
                    disabled={busy}
                    className="rounded-md px-1.5 py-0.5 text-[11px] font-medium text-primary transition-colors hover:bg-primary/10 disabled:opacity-50"
                    onClick={() => setPickedAccounts(
                      pickedAccounts.length === accounts.length ? [] : accounts.map((a) => a.file),
                    )}
                  >
                    {pickedAccounts.length === accounts.length ? t('accounts.probeClear') : t('accounts.probeSelectAll')}
                  </button>
                </div>
                <div className="max-h-[180px] overflow-y-auto rounded-lg border border-border/50 bg-background">
                  {accounts.length === 0 && (
                    <div className="p-3 text-center text-[11px] text-muted-foreground">
                      {t('dashboard.noAccounts')}
                    </div>
                  )}
                  {accounts.map((a) => {
                    const checked = pickedAccounts.includes(a.file);
                    return (
                      <div key={a.file}
                           role="checkbox"
                           aria-checked={checked}
                           aria-disabled={busy}
                           tabIndex={busy ? -1 : 0}
                           onClick={() => { if (!busy) setPickedAccounts((v) => toggle(v, a.file)); }}
                           onKeyDown={(e) => {
                             if (e.key === ' ' || e.key === 'Enter') {
                               e.preventDefault();
                               if (!busy) setPickedAccounts((v) => toggle(v, a.file));
                             }
                             // 阻止 Space 触发页面/容器滚动
                             if (e.key === ' ') e.stopPropagation();
                           }}
                           // 不用 <label><input class="sr-only">：input 获焦点时浏览器
                           // 会自动 scrollIntoView，在 transform: translate(-50%,-50%)
                           // 的 dialog 容器里会把整棵子树推到视口外（表现为「点选后
                           // 弹窗白屏」）。改用 role=checkbox 自己处理点击/键盘。
                           className={`flex cursor-pointer items-center gap-2.5 border-b border-border/40 px-2.5 py-2 text-[12px] transition-colors last:border-0 hover:bg-muted/60 focus-visible:outline-none focus-visible:bg-muted/60 ${checked ? 'bg-primary/5' : ''} ${busy ? 'cursor-not-allowed opacity-60' : ''}`}>
                        <span className={`flex size-4 shrink-0 items-center justify-center rounded border transition-colors ${
                          checked
                            ? 'border-primary bg-primary text-primary-foreground'
                            : 'border-muted-foreground/40 bg-background'
                        }`}>
                          {checked && <Check className="size-3" strokeWidth={3} />}
                        </span>
                        <span className={`truncate ${checked ? 'font-medium text-foreground' : 'text-foreground/80'}`}>
                          {a.nickname || a.uid || a.file}
                        </span>
                      </div>
                    );
                  })}
                </div>
              </div>

              {/* 模型 */}
              <div className="rounded-xl border border-border/60 bg-muted/30 p-3">
                <div className="mb-2 flex items-center justify-between">
                  <span className="flex items-center gap-1.5 text-xs font-semibold text-foreground/90">
                    {t('accounts.probeModels')}
                    <span className="rounded-full bg-primary/10 px-1.5 py-0.5 text-[10px] font-medium tabular-nums text-primary">
                      {pickedModels.length}/{models.length}
                    </span>
                  </span>
                  <button
                    type="button"
                    disabled={busy}
                    className="rounded-md px-1.5 py-0.5 text-[11px] font-medium text-primary transition-colors hover:bg-primary/10 disabled:opacity-50"
                    onClick={() => setPickedModels(
                      pickedModels.length === models.length ? [] : models.map((m) => m.id),
                    )}
                  >
                    {pickedModels.length === models.length ? t('accounts.probeClear') : t('accounts.probeSelectAll')}
                  </button>
                </div>
                <div className="max-h-[180px] overflow-y-auto rounded-lg border border-border/50 bg-background">
                  {models.length === 0 && (
                    <div className="p-3 text-center text-[11px] text-muted-foreground">
                      {t('accounts.probeNoModels')}
                    </div>
                  )}
                  {models.map((m) => {
                    const checked = pickedModels.includes(m.id);
                    return (
                      <div key={m.id}
                           role="checkbox"
                           aria-checked={checked}
                           aria-disabled={busy}
                           tabIndex={busy ? -1 : 0}
                           onClick={() => { if (!busy) setPickedModels((v) => toggle(v, m.id)); }}
                           onKeyDown={(e) => {
                             if (e.key === ' ' || e.key === 'Enter') {
                               e.preventDefault();
                               if (!busy) setPickedModels((v) => toggle(v, m.id));
                             }
                             if (e.key === ' ') e.stopPropagation();
                           }}
                           // 不用 <label><input class="sr-only">：理由同账号列表上方注释
                           className={`flex cursor-pointer items-center gap-2.5 border-b border-border/40 px-2.5 py-2 text-[12px] transition-colors last:border-0 hover:bg-muted/60 focus-visible:outline-none focus-visible:bg-muted/60 ${checked ? 'bg-primary/5' : ''} ${busy ? 'cursor-not-allowed opacity-60' : ''}`}>
                        <span className={`flex size-4 shrink-0 items-center justify-center rounded border transition-colors ${
                          checked
                            ? 'border-primary bg-primary text-primary-foreground'
                            : 'border-muted-foreground/40 bg-background'
                        }`}>
                          {checked && <Check className="size-3" strokeWidth={3} />}
                        </span>
                        <span className={`truncate ${checked ? 'font-medium text-foreground' : 'text-foreground/80'}`}
                              title={m.id}>
                          {m.name || m.id}
                        </span>
                      </div>
                    );
                  })}
                </div>
              </div>
            </div>

            <div className="flex flex-wrap items-center gap-x-2 gap-y-1.5 text-[11px]">
              <span className="inline-flex items-center gap-1.5 rounded-full bg-muted px-2.5 py-1 font-medium text-foreground/80">
                {t('accounts.probeRequests', {n: combos})}
              </span>
              <span className="inline-flex items-center gap-1.5 rounded-full bg-muted px-2.5 py-1 font-medium text-foreground/80">
                {t('accounts.probeBatchProgress', {done: completed, total: combos, batches: batches.length})}
              </span>
              <button
                type="button"
                disabled={busy}
                className="inline-flex items-center gap-1 rounded-full bg-primary/10 px-2.5 py-1 font-medium text-primary transition-colors hover:bg-primary/20 disabled:opacity-50"
                onClick={selectRestricted}
              >
                {t('accounts.probeSelectRestricted')}
              </button>
            </div>
            <p className="text-[11px] leading-relaxed text-muted-foreground">{t('accounts.probeAutoRecoveryHint')}</p>
            {busy && <progress className="h-1.5 w-full accent-primary" max={Math.max(1, combos)} value={completed} />}

            {error && (
              <div className="flex items-start gap-2 rounded-xl border border-red-500/30 bg-red-500/8 px-3 py-2.5 text-[11px] text-red-700 dark:text-red-300">
                <TriangleAlert className="mt-0.5 size-3.5 shrink-0" />
                <span>{error}</span>
              </div>
            )}

            {result && (
              <div className="space-y-3">
                <div className="flex flex-wrap gap-1.5">
                  <span className="inline-flex items-center gap-1.5 rounded-full bg-primary/10 px-2.5 py-1 text-[11px] font-medium text-primary">
                    {t('accounts.probeSynced', {n: result.results.filter((r) => r.gateway_synced).length})}
                  </span>
                  {STATUS_ORDER.filter((s) => (result.summary[s] ?? 0) > 0).map((s) => (
                    <span key={s}
                          className={`inline-flex items-center gap-1.5 rounded-full px-2.5 py-1 text-[11px] font-medium ${STATUS_STYLE[s]}`}>
                      {t(STATUS_KEY[s])}
                      <span className="font-semibold tabular-nums">{result.summary[s]}</span>
                    </span>
                  ))}
                </div>
                {result.results.some((r) => r.gateway_synced === false && !r.gateway_sync_skipped) && (
                  <p className="text-[11px] text-amber-600">{t('accounts.probeSyncFailed')}</p>
                )}
                <div className="max-h-[32vh] overflow-auto rounded-xl border border-border/60">
                  <table className="w-full border-collapse text-[11px]">
                    <thead className="sticky top-0 z-10 bg-background">
                      <tr className="border-b border-border/60 bg-muted/60">
                        <th className="whitespace-nowrap px-3 py-2 text-left text-[11px] font-semibold text-foreground/80">
                          {t('accounts.probeAccounts')}
                        </th>
                        {pickedModels.map((m) => (
                          <th key={m}
                              className="whitespace-nowrap px-2 py-2 text-center text-[11px] font-semibold text-foreground/80"
                              title={m}>
                            {modelName(m)}
                          </th>
                        ))}
                      </tr>
                    </thead>
                    <tbody>
                      {accounts.filter((a) => pickedAccounts.includes(a.file)).map((a) => (
                        <tr key={a.file}
                            className="border-b border-border/40 transition-colors last:border-0 hover:bg-muted/40">
                          <td className="max-w-[180px] truncate px-3 py-2 font-medium text-foreground/90"
                              title={a.file}>
                            {a.nickname || a.uid || a.file}
                          </td>
                          {pickedModels.map((m) => {
                            const r = matrix.get(`${a.file}\u0000${m}`);
                            return (
                              <td key={m} className="px-1.5 py-1.5 text-center">
                                {r ? (
                                  <span
                                    className={`inline-block whitespace-nowrap rounded-full px-2.5 py-0.5 font-medium ${STATUS_STYLE[r.status]}`}
                                    title={`${t(STATUS_KEY[r.status])}\n${r.message}${r.gateway_sync_message ? `\n${r.gateway_sync_message}` : ''}`}
                                  >
                                    {t(STATUS_KEY[r.status])}
                                  </span>
                                ) : (
                                  <Minus className="mx-auto size-3 text-muted-foreground/50" />
                                )}
                              </td>
                            );
                          })}
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              </div>
            )}
          </div>
        </div>

        <DialogFooter className="border-t border-border/50">
          <Button variant="ghost" size="sm" className="rounded-full"
                  disabled={stopping} onClick={() => {
                    if (busy) { stopRequested.current = true; setStopping(true); }
                    else onOpenChange(false);
                  }}>
            {busy ? t(stopping ? 'accounts.probeStopping' : 'accounts.probeStop') : t('common.cancel')}
          </Button>
          <Button size="sm" className="rounded-full" disabled={!canRun} onClick={run}>
            {busy ? <Loader2 className="mr-1.5 size-3.5 animate-spin" /> : null}
            {busy ? t('accounts.probeRunning') : t('accounts.probeRun')}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
