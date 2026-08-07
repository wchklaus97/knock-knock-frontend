FROM node:22-bookworm-slim

WORKDIR /app
ENV NODE_ENV=production

RUN corepack enable && corepack prepare pnpm@9.1.1 --activate
COPY package.json pnpm-workspace.yaml pnpm-lock.yaml ./
COPY apps/api/package.json apps/api/package.json
COPY apps/mcp/package.json apps/mcp/package.json
RUN pnpm install --frozen-lockfile

COPY apps/api apps/api
COPY contracts contracts
RUN pnpm --filter @vab/api build

RUN mkdir -p /data
EXPOSE 8787
CMD ["pnpm", "--filter", "@vab/api", "start:prod"]
