"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { useAuth } from "@/hooks/use-auth";
import { ChevronLeft, LogOut, Menu, Settings as SettingsIcon, User } from "lucide-react";
import {
  Avatar,
  AvatarFallback,
  AvatarImage,
} from "@/components/ui/avatar";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { ModeToggle } from "@/components/layout/mode-toggle";

/**
 * Section roots, for the "back to section" crumb on sub-pages.
 *
 * `/agents` and `/flows` used to be missing here, and the old lookup
 * fell back to "dashboard" when nothing matched — so the AI Agents and
 * Flows screens both announced themselves as "Dashboard" in the top
 * bar. They're listed now, and the fallback is gone: an unknown route
 * gets no crumb rather than a wrong one.
 */
const sectionLabels: Record<string, string> = {
  "/dashboard": "dashboard",
  "/inbox": "inbox",
  "/notifications": "notifications",
  "/contacts": "contacts",
  "/pipelines": "pipelines",
  "/resumen": "resumen",
  "/broadcasts": "broadcasts",
  "/automations": "automations",
  "/flows": "flows",
  "/agents": "aiAgents",
  "/settings": "settings",
};

/**
 * The parent section of a sub-page, or null when we're already at a
 * section root (or somewhere unrecognised).
 *
 * The top bar deliberately shows *nothing* at a section root. It used
 * to render `<h1>{section}</h1>` there, directly above the page's own
 * `<h1>` — two level-one headings per screen saying the same word, and
 * roughly 70px of chrome spent saying it twice. The page owns its
 * title now (see PageHeader); the bar only speaks up when it has
 * something the page doesn't, which is the way back.
 */
function getParentSection(
  pathname: string,
): { href: string; labelKey: string } | null {
  if (sectionLabels[pathname]) return null;
  const entry = Object.entries(sectionLabels).find(([path]) =>
    pathname.startsWith(`${path}/`),
  );
  return entry ? { href: entry[0], labelKey: entry[1] } : null;
}

/**
 * Full-bleed routes that deliberately have no `<h1>` of their own.
 *
 * Inbox is a three-pane messaging surface where a title row would cost
 * real estate the panes need, so it doesn't get a PageHeader. On
 * desktop the highlighted sidebar row says where you are; on mobile the
 * sidebar is a closed drawer, so the bar says it instead. Every other
 * route owns its title and gets nothing here — that's what stops the
 * name appearing twice.
 */
const MOBILE_LABEL_ROUTES: Record<string, string> = {
  "/inbox": "inbox",
};

interface HeaderProps {
  /** Wired to the shell's drawer state. Used only on mobile — the
   *  hamburger button is hidden on lg+. */
  onOpenSidebar?: () => void;
}

import { useTranslations } from "next-intl";

export function Header({ onOpenSidebar }: HeaderProps) {
  const t = useTranslations("Header");
  const pathname = usePathname();
  const { profile, signOut } = useAuth();
  const parent = getParentSection(pathname);

  const initial =
    profile?.full_name?.charAt(0)?.toUpperCase() ??
    profile?.email?.charAt(0)?.toUpperCase() ??
    "U";

  return (
    <header className="flex h-14 shrink-0 items-center justify-between gap-3 border-b border-border bg-background px-4 lg:px-6">
      <div className="flex min-w-0 items-center gap-2">
        {/* Hamburger — mobile only. 44×44 hit target per Apple HIG. */}
        <button
          type="button"
          onClick={onOpenSidebar}
          aria-label={t("openMenu")}
          className="flex h-10 w-10 items-center justify-center rounded-md text-muted-foreground transition-colors hover:bg-muted hover:text-foreground lg:hidden"
        >
          <Menu className="h-5 w-5" />
        </button>
        {/* Sub-pages only. A plain link back to the section they sit
            under — /broadcasts/new, /automations/[id]/logs and
            /flows/[id]/runs all had no way back short of the browser
            button or re-clicking the sidebar. */}
        {parent ? (
          <nav aria-label={t("breadcrumb")} className="min-w-0">
            <Link
              href={parent.href}
              className="flex min-w-0 items-center gap-1 rounded-md px-1.5 py-1 text-sm text-muted-foreground transition-colors hover:bg-muted hover:text-foreground focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-ring"
            >
              <ChevronLeft className="size-4 shrink-0" aria-hidden />
              <span className="truncate">{t(parent.labelKey as string)}</span>
            </Link>
          </nav>
        ) : null}
        {MOBILE_LABEL_ROUTES[pathname] ? (
          <span className="truncate text-base font-semibold text-foreground lg:hidden">
            {t(MOBILE_LABEL_ROUTES[pathname] as string)}
          </span>
        ) : null}
      </div>

      <div className="flex items-center gap-1 sm:gap-2">
        <ModeToggle />

        <DropdownMenu>
        <DropdownMenuTrigger
          className="flex items-center gap-2 rounded-md px-1 py-1 transition-colors hover:bg-muted/70 focus:bg-muted/70 focus:outline-none data-popup-open:bg-muted/70 sm:gap-3 sm:pl-1 sm:pr-3"
          aria-label={t("openAccountMenu")}
        >
          <Avatar className="size-8">
            {profile?.avatar_url ? (
              <AvatarImage
                src={profile.avatar_url}
                alt={profile.full_name ?? t("defaultAvatar")}
              />
            ) : null}
            <AvatarFallback className="bg-primary/10 text-sm font-medium text-primary">
              {initial}
            </AvatarFallback>
          </Avatar>
          <span className="hidden text-sm font-medium text-foreground sm:inline">
            {profile?.full_name ?? t("defaultUser")}
          </span>
        </DropdownMenuTrigger>
        <DropdownMenuContent
          align="end"
          sideOffset={6}
          className="min-w-56 bg-popover text-popover-foreground ring-border"
        >
          <div className="px-2 py-1.5">
            <p className="truncate text-sm font-medium text-foreground">
              {profile?.full_name ?? t("defaultUser")}
            </p>
            <p className="truncate text-xs text-muted-foreground">
              {profile?.email ?? ""}
            </p>
          </div>
          <DropdownMenuSeparator className="bg-border" />
          <DropdownMenuItem
            render={
              <Link
                href="/settings?tab=profile"
                className="text-popover-foreground focus:bg-accent focus:text-accent-foreground"
              />
            }
          >
            <User className="size-4" />
            {t("menuProfile")}
          </DropdownMenuItem>
          <DropdownMenuItem
            render={
              <Link
                href="/settings?tab=whatsapp"
                className="text-popover-foreground focus:bg-accent focus:text-accent-foreground"
              />
            }
          >
            <SettingsIcon className="size-4" />
            {t("menuSettings")}
          </DropdownMenuItem>
          <DropdownMenuSeparator className="bg-border" />
          <DropdownMenuItem
            onClick={signOut}
            className="text-popover-foreground focus:bg-accent focus:text-accent-foreground"
          >
            <LogOut className="size-4" />
            {t("menuSignOut")}
          </DropdownMenuItem>
        </DropdownMenuContent>
        </DropdownMenu>
      </div>
    </header>
  );
}
