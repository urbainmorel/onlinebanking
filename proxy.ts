import { createServerClient, type CookieOptions } from '@supabase/ssr';
import { NextResponse, type NextRequest } from 'next/server';
import { PERMISSIONS_POLICY } from './lib/security/browser-policy';
import {
  applySupabaseResponseMutations,
  EMPTY_SUPABASE_RESPONSE_MUTATIONS,
  recordSupabaseResponseMutations,
} from './lib/security/proxy-response';

const USER_PATHS = ['/myaccount', '/onboarding'];
const STAFF_PATHS = ['/admin'];
const AUTH_PATHS = ['/login', '/admin-login', '/admin/login', '/register', '/reset-pin'];
const NON_INDEXABLE_PATHS = ['/api', '/admin', '/admin-login', '/auth', '/myaccount', '/onboarding', '/reset-pin'];

function startsWithAny(pathname: string, prefixes: string[]) {
  return prefixes.some((prefix) => pathname === prefix || pathname.startsWith(`${prefix}/`));
}

function safeRemoteOrigin(value: string | undefined) {
  if (!value) return '';
  try {
    const url = new URL(value);
    return ['http:', 'https:'].includes(url.protocol) ? url.origin : '';
  } catch {
    return '';
  }
}

type ProxyCookieMethods = {
  getAll():
    | { name: string; value: string }[]
    | null
    | Promise<{ name: string; value: string }[] | null>;
  setAll(
    cookies: { name: string; value: string; options: CookieOptions }[],
    headers: Record<string, string>,
  ): void | Promise<void>;
};

type ProxySupabaseClient = {
  auth: {
    getClaims(): Promise<{
      data: { claims: { sub?: string } } | null;
    }>;
  };
  rpc(name: 'current_app_role'): Promise<{ data: unknown }>;
};

export type ProxyDependencies = {
  supabaseUrl?: string;
  supabaseKey?: string;
  nodeEnv?: string;
  createNonce(): string;
  createClient(
    url: string,
    key: string,
    options: { cookies: ProxyCookieMethods },
  ): ProxySupabaseClient;
};

const productionClientFactory: ProxyDependencies['createClient'] = (url, key, options) =>
  createServerClient(url, key, options) as unknown as ProxySupabaseClient;

export async function handleProxy(request: NextRequest, dependencies: ProxyDependencies) {
  const { supabaseUrl, supabaseKey, nodeEnv } = dependencies;
  const nonce = dependencies.createNonce();
  const remoteOrigin = safeRemoteOrigin(supabaseUrl);
  const contentSecurityPolicy = [
    "default-src 'self'",
    `script-src 'self' 'nonce-${nonce}' 'strict-dynamic' https://*.tawk.to https://cdn.jsdelivr.net${nodeEnv === 'development' ? " 'unsafe-eval'" : ''}`,
    "style-src 'self' 'unsafe-inline' https://*.tawk.to https://fonts.googleapis.com https://cdn.jsdelivr.net",
    `img-src 'self' data: blob: ${remoteOrigin} https://*.tawk.to https://cdn.jsdelivr.net https://tawk.link https://s3.amazonaws.com`.trim(),
    "font-src 'self' data: https://*.tawk.to https://fonts.gstatic.com",
    `connect-src 'self' ${remoteOrigin} https://*.tawk.to wss://*.tawk.to`.trim(),
    "media-src 'self' blob:",
    "object-src 'none'",
    "base-uri 'self'",
    "form-action 'self' https://*.tawk.to",
    "frame-src https://*.tawk.to",
    "frame-ancestors 'none'",
    "worker-src 'self' blob:",
    nodeEnv === 'production' ? 'upgrade-insecure-requests' : '',
  ]
    .filter(Boolean)
    .join('; ');

  const forwardedRequestHeaders = () => {
    const headers = new Headers(request.headers);
    headers.set('x-nonce', nonce);
    headers.set('Content-Security-Policy', contentSecurityPolicy);
    return headers;
  };

  const withSecurityHeaders = (target: NextResponse) => {
    target.headers.set('Content-Security-Policy', contentSecurityPolicy);
    target.headers.set('Referrer-Policy', 'strict-origin-when-cross-origin');
    target.headers.set('X-Content-Type-Options', 'nosniff');
    target.headers.set('X-Frame-Options', 'DENY');
    target.headers.set('Permissions-Policy', PERMISSIONS_POLICY);
    if (startsWithAny(request.nextUrl.pathname, NON_INDEXABLE_PATHS)) {
      target.headers.set('X-Robots-Tag', 'noindex, nofollow, noarchive');
    }
    return target;
  };

  let supabaseResponseMutations = EMPTY_SUPABASE_RESPONSE_MUTATIONS;
  const finalizeResponse = (target: NextResponse) =>
    withSecurityHeaders(
      applySupabaseResponseMutations(target, supabaseResponseMutations),
    );
  const nextResponse = () =>
    finalizeResponse(
      NextResponse.next({ request: { headers: forwardedRequestHeaders() } }),
    );
  const redirectResponse = (url: URL) =>
    finalizeResponse(NextResponse.redirect(url));

  if (!supabaseUrl || !supabaseKey) {
    if (startsWithAny(request.nextUrl.pathname, [...USER_PATHS, ...STAFF_PATHS])) {
      const loginUrl = request.nextUrl.clone();
      loginUrl.pathname = startsWithAny(request.nextUrl.pathname, STAFF_PATHS)
        ? '/admin-login'
        : '/login';
      loginUrl.searchParams.set('error', 'configuration');
      return redirectResponse(loginUrl);
    }
    return nextResponse();
  }

  let response = nextResponse();
  const supabase = dependencies.createClient(supabaseUrl, supabaseKey, {
    cookies: {
      getAll() {
        return request.cookies.getAll();
      },
      setAll(cookiesToSet, headersToSet) {
        cookiesToSet.forEach(({ name, value }) => request.cookies.set(name, value));
        supabaseResponseMutations = recordSupabaseResponseMutations(
          supabaseResponseMutations,
          cookiesToSet,
          headersToSet,
        );
        response = nextResponse();
      },
    },
  });

  const { data: claimsResult } = await supabase.auth.getClaims();
  const isAuthenticated = Boolean(claimsResult?.claims.sub);
  const pathname = request.nextUrl.pathname;
  const isPasswordRecovery =
    pathname === '/reset-pin' && request.nextUrl.searchParams.get('mode') === 'update';

  if (
    !isAuthenticated &&
    (startsWithAny(pathname, [...USER_PATHS, ...STAFF_PATHS]) || isPasswordRecovery)
  ) {
    if (isPasswordRecovery) {
      const recoveryUrl = request.nextUrl.clone();
      recoveryUrl.search = '';
      recoveryUrl.searchParams.set('error', 'recovery_session');
      return redirectResponse(recoveryUrl);
    }
    const loginUrl = request.nextUrl.clone();
    loginUrl.pathname = startsWithAny(pathname, STAFF_PATHS) ? '/admin-login' : '/login';
    loginUrl.searchParams.set('next', pathname);
    return redirectResponse(loginUrl);
  }

  if (isAuthenticated && startsWithAny(pathname, STAFF_PATHS)) {
    const { data: appRole } = await supabase.rpc('current_app_role');
    if (!appRole || appRole === 'user') {
      const accountUrl = request.nextUrl.clone();
      accountUrl.pathname = '/myaccount';
      accountUrl.searchParams.set('error', 'staff_required');
      return redirectResponse(accountUrl);
    }
  }

  if (isAuthenticated && startsWithAny(pathname, AUTH_PATHS) && !isPasswordRecovery) {
    const targetUrl = request.nextUrl.clone();
    const { data: appRole } = await supabase.rpc('current_app_role');
    targetUrl.pathname = appRole && appRole !== 'user' ? '/admin' : '/myaccount';
    targetUrl.search = '';
    return redirectResponse(targetUrl);
  }

  return response;
}

export async function proxy(request: NextRequest) {
  return handleProxy(request, {
    supabaseUrl: process.env.NEXT_PUBLIC_SUPABASE_URL,
    supabaseKey:
      process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY ??
      process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY,
    nodeEnv: process.env.NODE_ENV,
    createNonce: () => crypto.randomUUID(),
    createClient: productionClientFactory,
  });
}

export const config = {
  matcher: [
    '/((?!_next/static|_next/image|favicon.ico|manifest.webmanifest|robots.txt|sitemap.xml|brand|assets).*)',
  ],
};
