import './globals.css';
import { cookies, headers } from 'next/headers';
import type { Metadata, Viewport } from 'next';
import Providers from '@/components/Providers';
import {
  LANGUAGE_COOKIE,
  LANGUAGE_SOURCE_COOKIE,
  parseAcceptLanguage,
  resolveInitialLanguage,
} from '@/lib/language';
import { isPublicSupabaseConfigured } from '@/lib/supabase/config';
import { createClient } from '@/lib/supabase/server';
import { getRequestBrandSettings } from '@/lib/server/branding';
import LegalFooter from '@/components/legal/LegalFooter';
import { CANONICAL_ORIGIN } from '@/lib/seo';

const description =
  'Instructions, contrôles et traçabilité d’opérations financières exécutées hors application.';

export const viewport: Viewport = {
  width: 'device-width',
  initialScale: 1,
  // Keep the full application inside the device safe area. The floating chat
  // launcher still adds env(safe-area-inset-*) spacing where it is available.
  viewportFit: 'contain',
};

export async function generateMetadata(): Promise<Metadata> {
  const brand = await getRequestBrandSettings();
  const googleVerification = process.env.NEXT_PUBLIC_GOOGLE_SITE_VERIFICATION?.trim();
  return {
    metadataBase: new URL(CANONICAL_ORIGIN),
    applicationName: brand.bankName,
    title: {
      default: brand.bankName,
      template: `%s | ${brand.bankName}`,
    },
    description,
    manifest: '/manifest.webmanifest',
    category: 'finance',
    robots: {
      index: true,
      follow: true,
      googleBot: {
        index: true,
        follow: true,
        'max-image-preview': 'large',
        'max-snippet': -1,
        'max-video-preview': -1,
      },
    },
    verification: googleVerification ? { google: googleVerification } : undefined,
    icons: {
      icon: [
        { url: brand.faviconIcoUrl, sizes: '16x16 32x32 48x48' },
        { url: brand.favicon16Url, type: 'image/png', sizes: '16x16' },
        { url: brand.favicon32Url, type: 'image/png', sizes: '32x32' },
        { url: brand.favicon48Url, type: 'image/png', sizes: '48x48' },
      ],
      apple: [
        { url: brand.appleTouchIconUrl, type: 'image/png', sizes: '180x180' },
      ],
    },
    openGraph: {
      type: 'website',
      siteName: brand.bankName,
      url: CANONICAL_ORIGIN,
      title: brand.bankName,
      description,
      images: [
        {
          url: brand.socialCardUrl,
          width: 1200,
          height: 630,
          alt: brand.bankName,
        },
      ],
    },
    twitter: {
      card: 'summary_large_image',
      title: brand.bankName,
      description,
      images: [brand.socialCardUrl],
    },
  };
}

export default async function RootLayout({children}: {children: React.ReactNode}) {
  // Nonce-based CSP requires every HTML response to be rendered with the
  // per-request nonce injected by proxy.ts.
  const requestHeaders = await headers();
  const cookieStore = await cookies();
  let profileLanguage: string | null = null;

  const hasAuthToken = cookieStore.getAll().some((c) => c.name.startsWith('sb-'));

  if (hasAuthToken && isPublicSupabaseConfigured()) {
    try {
      const supabase = await createClient();
      const {
        data: { user },
      } = await supabase.auth.getUser();
      if (user) {
        const { data: profile, error } = await supabase
          .from('profiles')
          .select('preferred_language')
          .eq('user_id', user.id)
          .maybeSingle();
        if (!error) profileLanguage = profile?.preferred_language ?? null;
      }
    } catch {
      // A transient profile read must not prevent public pages from rendering.
      // The client will retry profile hydration through its normal data refresh.
    }
  }

  const initialLanguage = resolveInitialLanguage({
    profileLanguage,
    cookieLanguage: cookieStore.get(LANGUAGE_COOKIE)?.value,
    cookieSource: cookieStore.get(LANGUAGE_SOURCE_COOKIE)?.value,
    acceptedLanguages: parseAcceptLanguage(requestHeaders.get('accept-language')),
  });
  const initialBrand = await getRequestBrandSettings();
  const organizationJsonLd = {
    '@context': 'https://schema.org',
    '@type': 'Organization',
    name: initialBrand.bankName,
    legalName: '2 C FINANCE',
    alternateName: initialBrand.bankName.toUpperCase(),
    url: CANONICAL_ORIGIN,
    logo: new URL(initialBrand.primaryLogoUrl, CANONICAL_ORIGIN).toString(),
    email: process.env.NEXT_PUBLIC_SUPPORT_EMAIL ?? 'support@monalyz.com',
    identifier: [
      { '@type': 'PropertyValue', propertyID: 'SIREN', value: '979 247 145' },
      { '@type': 'PropertyValue', propertyID: 'SIRET', value: '979 247 145 00019' },
    ],
    address: {
      '@type': 'PostalAddress',
      streetAddress: '20 BOULEVARD MONTMARTRE',
      postalCode: '75009',
      addressLocality: 'PARIS',
      addressCountry: 'FR',
    },
  };

  return (
    <html lang={initialLanguage.language}>
      <body suppressHydrationWarning>
        <script
          nonce={requestHeaders.get('x-nonce') ?? undefined}
          type="application/ld+json"
          dangerouslySetInnerHTML={{
            __html: JSON.stringify(organizationJsonLd).replaceAll('<', '\\u003c'),
          }}
        />
        <Providers
          initialLanguage={initialLanguage.language}
          initialLanguageSource={initialLanguage.source}
          initialBrand={initialBrand}
        >
          {children}
          <LegalFooter bankName={initialBrand.bankName} />
        </Providers>
      </body>
    </html>
  );
}
