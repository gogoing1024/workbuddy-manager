'use client';

import {useEffect, useMemo, useState} from 'react';
import {CheckCircle2, RefreshCw, TriangleAlert, Users} from 'lucide-react';
import {useT} from '@/lib/i18n/provider';
import type {Account} from '@/lib/types';
import {availabilityLabelKey, availabilityOf} from '@/lib/account-status';
import {Badge} from '@/components/ui/badge';
import {Button} from '@/components/ui/button';
import {
  Dialog,
  DialogBody,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
} from '@/components/animate-ui/radix/dialog';
import {AddAccountDialog} from './AddAccountDialog';

/**
 * 解禁队列弹窗：把「封控」账号（上游自动禁用，含 11140 被封）排成一列，
 * 支持依次或按指定账号进行重新扫码登录解封。
 */
export function ReloginQueueDialog({
  open,
  onOpenChange,
  accounts,
  upstreamId,
  onSuccess,
  adminApiEnabled,
}: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  /** 已合并池状态、并按当前版本过滤后的账号列表 */
  accounts: Account[];
  upstreamId?: number | null;
  onSuccess?: () => void;
  /** 上游「账号管理接口」（admin.enabled）开关；false = 未开启，解封不可用 */
  adminApiEnabled?: boolean | null;
}) {
  const t = useT();
  const [reloginOpen, setReloginOpen] = useState(false);
  const [selectedIndex, setSelectedIndex] = useState(0);

  // 封控 = 上游自动禁用（`disabled`）。「已停用」（面板改名 / 上游手动位）是用户主动摘除，不进封控队列。
  const queue = useMemo(
    () => accounts.filter((a) => availabilityOf(a) === 'disabled'),
    [accounts],
  );

  // 账号解禁离开队列或总数缩减时，防止下标越界
  useEffect(() => {
    if (selectedIndex >= queue.length) {
      setSelectedIndex(Math.max(0, queue.length - 1));
    }
  }, [queue.length, selectedIndex]);

  /**
   * 重登成功后的收尾：立即刷新一次，并补几次延迟刷新。
   *
   * 为什么不能只刷一次：后端的「登录后自动解除系统禁用」（_revive_after_login）
   * 是后台任务，最长要等约 20 秒（等上游热加载 + revive）。前端立刻刷新拿到的
   * 仍是旧快照（账号还标着 disabled），于是账号会一直留在封禁队列里，直到 30s
   * 心跳才挪走。补几次延迟刷新，让账号在 revive 完成后尽快离开队列。
   */
  function handleReloginSuccess() {
    onSuccess?.();
    [3000, 8000, 15000].forEach((ms) => {
      window.setTimeout(() => onSuccess?.(), ms);
    });
  }

  function statusBadge(a: Account) {
    const tier = availabilityOf(a);
    const reason = String(a.disabled_reason || '');
    return (
      <Badge
        variant="destructive"
        className="rounded-full shrink-0 h-6 px-2.5 text-[11px] font-medium shadow-sm"
        title={reason ? t('accounts.disabledReason', {reason}) : undefined}
      >
        {t(availabilityLabelKey(tier, a))}
      </Badge>
    );
  }

  return (
    <>
      <Dialog open={open} onOpenChange={onOpenChange}>
        <DialogContent
          className="max-w-[640px] p-0 overflow-hidden"
          showCloseButton
        >
          <DialogHeader className="px-6 pt-5 pb-4 border-b border-border/40">
            <div className="flex items-center gap-3">
              <div className="grid h-9 w-9 place-items-center rounded-lg bg-primary/10 text-primary">
                <Users className="h-4 w-4" />
              </div>
              <div className="flex-1 min-w-0">
                <div className="flex items-center gap-2">
                  <DialogTitle className="text-base font-semibold tracking-tight">
                    {t('accounts.reloginQueueTitle')}
                  </DialogTitle>
                  <Badge
                    variant="secondary"
                    className="rounded-full text-[11px] h-5 px-2 font-medium"
                  >
                    {t('accounts.reloginQueueCount', {count: queue.length})}
                  </Badge>
                </div>
                <DialogDescription className="text-xs text-muted-foreground mt-0.5 space-y-1">
                  <p>{t('accounts.reloginQueueDesc')}</p>
                  {/* 上游管理接口未开启时，重登只换令牌、清不掉禁用位——必须先讲清，
                      避免用户白重登一遍才发现在白忙（与徽章悬停提示同一口径）。 */}
                  {adminApiEnabled === false && (
                    <p className="flex items-start gap-1.5 text-amber-700 dark:text-amber-300">
                      <TriangleAlert className="mt-0.5 h-3 w-3 shrink-0" />
                      <span>{t('accounts.disabledQueueHintAdminOff')}</span>
                    </p>
                  )}
                </DialogDescription>
              </div>
            </div>
          </DialogHeader>

          {queue.length === 0 ? (
            <div className="flex flex-col items-center justify-center py-14 px-6 text-center space-y-3">
              <div className="grid h-12 w-12 place-items-center rounded-full bg-emerald-500/10 text-emerald-600 dark:text-emerald-400">
                <CheckCircle2 className="h-6 w-6" />
              </div>
              <div className="text-sm font-medium">{t('accounts.reloginQueueEmptyTitle')}</div>
              <p className="text-xs text-muted-foreground max-w-sm">
                {t('accounts.reloginQueueEmptyDesc')}
              </p>
            </div>
          ) : (
            <DialogBody className="max-h-[min(560px,calc(100dvh-14rem))]">
              <div className="space-y-4 px-6 py-4">
              {/* 队列清单（点击任意行直接跳转并选中该账号） */}
              <div className="space-y-2">
                <div className="flex items-center justify-between px-1 text-xs font-medium">
                  <span className="text-muted-foreground">
                    {t('accounts.reloginQueueWaitingCount', {count: queue.length})}
                  </span>
                  <span className="text-[11px] text-muted-foreground/70">
                    {t('accounts.reloginQueueListHint')}
                  </span>
                </div>

                <div className="rounded-lg border border-border/50 divide-y divide-border/40 overflow-hidden bg-background shadow-sm">
                  {queue.map((a, i) => {
                    const isSelected = i === selectedIndex;
                    return (
                      <div
                        key={a.file}
                        onClick={() => setSelectedIndex(i)}
                        className={
                          'group relative flex items-center justify-between gap-3 px-3.5 py-3 transition-colors cursor-pointer ' +
                          (isSelected
                            ? 'bg-primary/10'
                            : 'hover:bg-muted/50')
                        }
                      >
                        {isSelected && (
                          <span className="absolute left-0 top-0 h-full w-[3px] bg-primary rounded-r-full" />
                        )}

                        <div className="flex items-center gap-3 min-w-0 pl-1">
                          <span
                            className={
                              'grid h-6 w-6 shrink-0 place-items-center rounded-full text-[10px] font-bold transition-colors ' +
                              (isSelected
                                ? 'bg-primary text-primary-foreground shadow-sm'
                                : 'bg-muted text-muted-foreground group-hover:bg-muted/80')
                            }
                          >
                            {i + 1}
                          </span>
                          <div className="min-w-0">
                            <div
                              className={
                                'text-xs font-medium truncate leading-tight ' +
                                (isSelected ? 'text-foreground' : 'text-foreground/90')
                              }
                            >
                              {a.nickname || t('accounts.unnamed')}
                            </div>
                            <div className="font-mono text-[10px] text-muted-foreground/80 truncate">
                              {a.uid}
                            </div>
                          </div>
                        </div>

                        <div className="flex items-center gap-1.5 shrink-0">
                          {statusBadge(a)}
                          <Button
                            size="sm"
                            variant="outline"
                            className="h-7 px-2.5 text-xs rounded-full gap-1 shadow-none"
                            onClick={(e) => {
                              e.stopPropagation();
                              setSelectedIndex(i);
                              setReloginOpen(true);
                            }}
                          >
                            <RefreshCw className="h-3 w-3" />
                            <span>{t('accounts.reloginQueueRelogin')}</span>
                          </Button>
                        </div>
                      </div>
                    );
                  })}
                </div>
              </div>

              <div className="flex items-center gap-2 px-1 pt-3 mt-1 border-t border-border/40 text-[11px] text-muted-foreground">
                <TriangleAlert className="h-3.5 w-3.5 shrink-0 text-amber-500" />
                <span>{t('accounts.reloginQueueAdvanceHint')}</span>
              </div>
              </div>
            </DialogBody>
          )}
        </DialogContent>
      </Dialog>

      <AddAccountDialog
        open={reloginOpen}
        onOpenChange={setReloginOpen}
        onSuccess={handleReloginSuccess}
        upstreamId={upstreamId}
      />
    </>
  );
}

export const ReloginQueue = ReloginQueueDialog;
