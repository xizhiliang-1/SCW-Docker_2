FROM nginx:stable

RUN rm /etc/nginx/conf.d/*

COPY nginx.conf /etc/nginx/nginx.conf

RUN touch /var/run/nginx.pid && \
    chown -R www-data:www-data /var/run/nginx.pid && \
    chown -R www-data:www-data /var/cache/nginx

USER www-data
