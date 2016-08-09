#!/bin/bash
# Example of a hook provided by a typical rails app..allows us to run anything
# In the container we've built but not yet released
echo "Running migrations on release $RELEASE_ID..."
convox run web db:migrate --app $APP_NAME --release $RELEASE_ID
