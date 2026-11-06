import type { MetadataRoute } from "next";
import { SITE_URL } from "@/lib/config";

export default function sitemap(): MetadataRoute.Sitemap {
  return [
    { url: SITE_URL, changeFrequency: "weekly", priority: 1 },
    { url: `${SITE_URL}/app/trade`, changeFrequency: "weekly", priority: 0.8 },
    { url: `${SITE_URL}/app/earn`, changeFrequency: "weekly", priority: 0.8 },
  ];
}
