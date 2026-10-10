'use client';

import {useMemo, useState} from 'react';
import {Check, ChevronsUpDown, Search, X} from 'lucide-react';
import {upstreamApi} from '@/lib/api';
import type {ModelInfo} from '@/lib/types';
import type {Realm} from '@/lib/realm-context';
import {useT} from '@/lib/i18n/provider';
import {Button} from '@/components/ui/button';
import {Input} from '@/components/ui/input';
import {Popover, PopoverContent, PopoverTrigger} from '@/components/ui/popover';
import {cn} from '@/lib/utils';

/**
 * 模型白名单输入（issue #141）：把「手打模型名」换成「从清单里勾」。
 *
 * 为什么保留输入框：清单里暂时没有的模型（新模型、私有部署、还没同步到的目录）仍然
 * 要能填 —— 候选只解决「记不住名字、写错了要等调用失败才发现」，不该变成新的门槛。
 *
 * 存储形态没变（仍是逗号/换行分隔的字符串），所以后端与既有密钥数据一行都不用动：
 * 勾选 = 往那个字符串里追加一个名字，取消 = 移除。
 *
 * 清单按**版本分组**展示（国内版 / 国际版）：白名单是在所选版本之内再收窄的，
 * 放在一起看不出哪个名字属于哪一版。
 *
 * 校验仍由父组件在输入框失焦时触发（与本组件引入前一致）；勾选进来的名字来自清单，
 * 本身不可能写错，因此不必再查一次。
 */
export function ModelWhitelistInput({
  value,
  onChange,
  onBlur,
  realm,
  placeholder,
  disabled = false,
}: {
  value: string;
  onChange: (next: string) => void;
  onBlur?: () => void;
  /** 当前密钥的限定版本；国际版清单排前面，便于对照 */
  realm?: Realm | '';
  placeholder?: string;
  disabled?: boolean;
}) {
  const t = useT();
  const names = useMemo(() => splitNames(value), [value]);
  const [draft, setDraft] = useState('');
  const [open, setOpen] = useState(false);
  const [query, setQuery] = useState('');
  const [catalog, setCatalog] = useState<{cn: ModelInfo[]; global: ModelInfo[]} | null>(null);
  const [failed, setFailed] = useState(false);

  /** 勾选/取消：按当前顺序重建字符串（去重，保持用户看到的次序） */
  function emit(next: string[]) {
    onChange(Array.from(new Set(next)).join(', '));
  }

  function add(name: string) {
    const clean = name.trim().replace(/,+$/, '');
    if (!clean) return;
    emit([...names, clean]);
    setDraft('');
  }

  function remove(name: string) {
    emit(names.filter((n) => n !== name));
  }

  /** 打开时（只拉一次）取两个版本的模型清单；取不到就如实说，不挡住手输 */
  async function ensureCatalog() {
    if (catalog || failed) return;
    try {
      const [cn, global] = await Promise.all([
        upstreamApi.models('cn'),
        upstreamApi.models('global'),
      ]);
      setCatalog({cn: cn.models, global: global.models});
    } catch {
      setFailed(true);
    }
  }

  const groups: {key: Realm; label: string; models: ModelInfo[]}[] = catalog
    ? [
        {key: 'global', label: t('realm.global'), models: catalog.global},
        {key: 'cn', label: t('realm.cn'), models: catalog.cn},
      ]
    : [];
  const needle = query.trim().toLowerCase();
  const filtered = groups
    .map((g) => ({
      ...g,
      models: needle ? g.models.filter((m) => m.id.toLowerCase().includes(needle)) : g.models,
    }))
    .filter((g) => g.models.length > 0);

  return (
    <div className={cn('space-y-1.5', realm === 'global' && 'order-first')}>
      {names.length > 0 && (
        <div className="flex flex-wrap gap-1">
          {names.map((name) => (
            <span
              key={name}
              className="inline-flex items-center gap-1 rounded-full bg-muted px-2 py-0.5 font-mono text-[10px]"
            >
              {name}
              {!disabled && (
                <button
                  type="button"
                  aria-label={t('keys.modelRemove', {name})}
                  onClick={() => remove(name)}
                  className="text-muted-foreground hover:text-foreground"
                >
                  <X className="h-3 w-3" />
                </button>
              )}
            </span>
          ))}
        </div>
      )}
      <div className="flex gap-1.5">
        <Input
          value={draft}
          disabled={disabled}
          placeholder={placeholder}
          onChange={(e) => {
            // 逗号是既有的分隔写法：粘贴一串名字时按它就拆开
            if (e.target.value.includes(',')) {
              e.target.value.split(',').forEach((part) => add(part));
              return;
            }
            setDraft(e.target.value);
          }}
          onKeyDown={(e) => {
            if (e.key === 'Enter') {
              e.preventDefault();
              add(draft);
            } else if (e.key === 'Backspace' && !draft && names.length) {
              remove(names[names.length - 1]);
            }
          }}
          onBlur={() => {
            if (draft.trim()) add(draft);
            onBlur?.();
          }}
        />
        <Popover
          open={open}
          onOpenChange={(next) => {
            setOpen(next);
            if (next) void ensureCatalog();
          }}
        >
          <PopoverTrigger asChild>
            <Button
              type="button"
              variant="outline"
              size="sm"
              disabled={disabled}
              className="shrink-0 rounded-full"
            >
              <ChevronsUpDown className="h-3.5 w-3.5" />
              {t('keys.modelPick')}
            </Button>
          </PopoverTrigger>
          <PopoverContent align="end" className="w-[320px] p-2">
            <div className="mb-2 flex items-center gap-1.5 rounded-full bg-muted px-2.5 py-1">
              <Search className="h-3.5 w-3.5 shrink-0 text-muted-foreground" />
              <input
                autoFocus
                value={query}
                onChange={(e) => setQuery(e.target.value)}
                placeholder={t('keys.modelPickSearch')}
                className="w-full bg-transparent text-xs outline-none"
              />
            </div>
            <div className="max-h-[260px] overflow-y-auto">
              {failed && (
                <p className="px-2 py-6 text-center text-xs text-muted-foreground">
                  {t('keys.modelPickUnavailable')}
                </p>
              )}
              {!failed && !catalog && (
                <p className="px-2 py-6 text-center text-xs text-muted-foreground">
                  {t('keys.modelPickLoading')}
                </p>
              )}
              {!failed && catalog && filtered.length === 0 && (
                <p className="px-2 py-6 text-center text-xs text-muted-foreground">
                  {t('keys.modelPickEmpty')}
                </p>
              )}
              {filtered.map((group) => (
                <div key={group.key} className="mb-1">
                  <div className="px-2 py-1 text-[10px] text-muted-foreground">{group.label}</div>
                  {group.models.map((m) => {
                    const picked = names.includes(m.id);
                    return (
                      <button
                        key={m.id}
                        type="button"
                        role="checkbox"
                        aria-checked={picked}
                        onClick={() => (picked ? remove(m.id) : add(m.id))}
                        className={cn(
                          'flex w-full items-center gap-2 rounded-md px-2 py-1.5 text-left text-xs',
                          'hover:bg-muted',
                          picked && 'bg-muted/70',
                        )}
                      >
                        <span
                          className={cn(
                            'flex h-3.5 w-3.5 shrink-0 items-center justify-center rounded border',
                            picked ? 'border-primary bg-primary text-primary-foreground' : 'border-border',
                          )}
                        >
                          {picked && <Check className="h-2.5 w-2.5" />}
                        </span>
                        <span className="min-w-0 flex-1 truncate font-mono">{m.id}</span>
                        {typeof m.context_length === 'number' && (
                          <span className="shrink-0 text-[10px] text-muted-foreground">
                            {Math.round(m.context_length / 1000)}k
                          </span>
                        )}
                      </button>
                    );
                  })}
                </div>
              ))}
            </div>
          </PopoverContent>
        </Popover>
      </div>
    </div>
  );
}

function splitNames(value: string): string[] {
  return Array.from(new Set(
    value.split(/[\n,]/).map((s) => s.trim()).filter(Boolean),
  ));
}
