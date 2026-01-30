This is a installation guide for the installation of the alert manager using prometheus and incus.
The installation can be done in two methods 

METHOD 1
This Method is used to do autodeploy in a fresh installtion of linux the file names is called auto_deploy.sh
use chmod +x and run the script using ./auto_deploy.sh

METHOD 2 
It is used to deploy things is parts using 3 scripts
The order goes this way
1)    incus.sh script installs the incus in the system
2)  deploy_containers.sh it will deploy 4 containers in the system
3)  container_config.sh it wll configure the alert manager and the containers configuration
    ATTENTION : it is necessory to add your credentials in the container_config.sh
                You can get one time password from https://myaccount.google.com/apppasswords

    if everything works properly you can use this command to test
    incus exec alertmanager -- curl -H "Content-Type: application/json" -d '[{"labels":{"alertname":"TestAlert"}}]' http://localhost:9093/api/v2/alerts/

The current file that i am working is called reinstall.sh 
