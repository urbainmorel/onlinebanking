import 'server-only';

import { cache } from 'react';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import type { SupabaseClient } from '@supabase/supabase-js';
import { createClient as createSupabaseJsClient } from '@supabase/supabase-js';
import {
  DEFAULT_BRAND_ROW,
  DEFAULT_BRAND_SETTINGS,
  mapBrandSettings,
  type BrandSettingsRow,
} from '@/lib/branding';
import { isPublicSupabaseConfigured, getPublicSupabaseConfig } from '@/lib/supabase/config';
import type { BrandSettings } from '@/lib/types';

export async function fetchBrandRow(
  client: SupabaseClient,
): Promise<BrandSettingsRow> {
  const { data, error } = await client
    .from('brand_settings')
    .select('*')
    .eq('singleton', true)
    .single();
  if (error || !data) throw error ?? new Error('Configuration de marque absente.');
  return data as BrandSettingsRow;
}

export async function resolveBrandSettings(
  client?: SupabaseClient,
): Promise<BrandSettings> {
  if (!isPublicSupabaseConfigured()) return DEFAULT_BRAND_SETTINGS;
  try {
    const { url, publishableKey } = getPublicSupabaseConfig();
    const effectiveClient = client ?? createSupabaseJsClient(url, publishableKey);
    const row = await fetchBrandRow(effectiveClient);
    return mapBrandSettings(row, url);
  } catch {
    return DEFAULT_BRAND_SETTINGS;
  }
}

export const getRequestBrandSettings = cache(resolveBrandSettings);

export async function readBrandAsset(
  client: SupabaseClient,
  assetPath: string,
): Promise<Uint8Array> {
  if (assetPath.startsWith('/')) {
    const safeRelativePath = assetPath.replace(/^\/+/, '');
    const absolutePath = path.resolve(process.cwd(), 'public', safeRelativePath);
    const publicRoot = path.resolve(process.cwd(), 'public');
    if (!absolutePath.startsWith(`${publicRoot}${path.sep}`)) {
      throw new Error('Chemin d’asset de marque invalide.');
    }
    return readFile(absolutePath);
  }
  const { data, error } = await client.storage.from('brand-assets').download(assetPath);
  if (error || !data) throw error ?? new Error('Asset de marque introuvable.');
  return new Uint8Array(await data.arrayBuffer());
}

export async function fetchBrandRowOrDefault(
  client: SupabaseClient,
): Promise<BrandSettingsRow> {
  try {
    return await fetchBrandRow(client);
  } catch {
    return DEFAULT_BRAND_ROW;
  }
}
