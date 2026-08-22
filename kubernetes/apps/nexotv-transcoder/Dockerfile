FROM node:20-slim

RUN apt-get update && \
    apt-get install -y ffmpeg intel-media-va-driver vainfo && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY package.json ./
RUN npm install

COPY transcoder.js ./

EXPOSE 7001

CMD ["node", "transcoder.js"]
