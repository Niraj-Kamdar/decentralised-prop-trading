/** @type {import('next').NextConfig} */
const nextConfig = {
  reactStrictMode: true,
  outputFileTracingRoot: import.meta.dirname,
  webpack: (config) => {
    // wagmi's optional connectors pull in modules that are not needed in the browser bundle.
    config.externals.push("pino-pretty", "lokijs", "encoding");
    config.resolve.alias = { ...config.resolve.alias, "@react-native-async-storage/async-storage": false };
    return config;
  },
};
export default nextConfig;
