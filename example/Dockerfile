FROM convox/sinatra

WORKDIR /app

COPY Gemfile      /app/Gemfile
COPY Gemfile.lock /app/Gemfile.lock
RUN bundle install --without development:test -j4

# copy the rest of the app
COPY . /app
