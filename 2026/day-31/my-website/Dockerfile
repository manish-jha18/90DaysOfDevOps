# Day 31 Task 4 - static site on nginx
# alpine variant: ~45MB instead of ~190MB for the full nginx image
FROM nginx:1.25-alpine

# nginx serves whatever is in this directory
COPY index.html /usr/share/nginx/html/index.html

EXPOSE 80

# the base image already sets the right CMD (nginx -g "daemon off;")
# so there is nothing to add here
