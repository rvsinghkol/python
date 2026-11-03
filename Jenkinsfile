// =====================================================================
// Production CI/CD: Maven -> Docker -> Trivy -> ECR -> Terraform -> ECS
// ACTION = deploy   : build new image, push to ECR, deploy with Terraform
// ACTION = rollback : pick an existing ECR image from a dropdown, deploy it
// Jenkins runs outside AWS: access keys of the IAM user 'docker-remote-jenkins'
// are stored in Jenkins as Secret text credentials.
// =====================================================================
pipeline {
    agent any

    options {
        disableConcurrentBuilds()                       // one prod change at a time
        buildDiscarder(logRotator(numToKeepStr: '30'))
        timeout(time: 90, unit: 'MINUTES')
    }

    tools {
        maven 'Maven'
    }

    parameters {
        choice(name: 'ACTION', choices: ['deploy', 'rollback'],
               description: 'deploy = build & release new code | rollback = choose an older image from ECR')
    }

    environment {
        AWS_ACCESS_KEY_ID     = credentials('aws-access-key-id')
        AWS_SECRET_ACCESS_KEY = credentials('aws-secret-access-key')
        AWS_DEFAULT_REGION = 'ap-south-1'
        AWS_ACCOUNT_ID     = '707479681461'
        ECR_REPO           = 'docker_remote'
        ECR_REGISTRY       = "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_DEFAULT_REGION}.amazonaws.com"
        IMAGE              = "${ECR_REGISTRY}/${ECR_REPO}"

        ECS_CLUSTER        = 'docker-remote-prod-cluster'
        ECS_SERVICE        = 'docker-remote-prod-service'

        TF_DIR             = 'terraform/app'
        TF_VARS_FILE       = 'prod.tfvars'
        TF_IN_AUTOMATION   = 'true'
        TF_INPUT           = '0'

        TRIVY_IMAGE        = 'aquasec/trivy:latest'    // pin a specific version for prod
    }

    stages {

        stage('Verify AWS access') {
            steps {
                sh 'aws sts get-caller-identity'
            }
        }

        // Always needed: Terraform code lives in the repo
        stage('Git checkout') {
            steps {
                checkout scmGit(branches: [[name: '*/master']], extensions: [],
                    userRemoteConfigs: [[credentialsId: 'github-token',
                    url: 'https://github.com/rvsinghkol/python.git']])
                script {
                    env.GIT_FULL  = sh(script: 'git rev-parse HEAD', returnStdout: true).trim()
                    env.GIT_SHORT = env.GIT_FULL.take(7)
                }
            }
        }

        stage('Prepare') {
            when { expression { params.ACTION == 'deploy' } }
            steps {
                script {
                    // Unique, immutable tag: v<build>-<commit>, e.g. v42-a1b2c3d
                    env.DEPLOY_TAG = "v${env.BUILD_NUMBER}-${env.GIT_SHORT}"
                    currentBuild.description = "Deploy ${env.DEPLOY_TAG}"
                }
            }
        }

        stage('Select Version from ECR') {
            when { expression { params.ACTION == 'rollback' } }
            steps {
                script {
                    def running = sh(script: '''
                        TD=$(aws ecs describe-services --cluster $ECS_CLUSTER --services $ECS_SERVICE \
                               --query 'services[0].taskDefinition' --output text 2>/dev/null || true)
                        if [ -n "$TD" ] && [ "$TD" != "None" ]; then
                          aws ecs describe-task-definition --task-definition $TD \
                            --query 'taskDefinition.containerDefinitions[0].image' --output text \
                            | awk -F: '{print $NF}'
                        fi
                    ''', returnStdout: true).trim()

                    def tags = sh(script: '''
                        aws ecr describe-images --repository-name $ECR_REPO --filter tagStatus=TAGGED \
                          --query 'sort_by(imageDetails,&imagePushedAt)[*].imageTags[0]' --output text
                    ''', returnStdout: true).trim().tokenize().findAll { it != 'None' }

                    if (tags.isEmpty()) { error "No images found in ECR repository ${ECR_REPO}" }

                    timeout(time: 15, unit: 'MINUTES') {
                        env.DEPLOY_TAG = input(
                            message: "PRODUCTION is running: ${running ?: 'unknown'}. Choose version to deploy:",
                            ok: 'Continue',
                            parameters: [choice(name: 'VERSION', choices: tags.reverse(),
                                                description: 'Newest first')]
                        )
                    }
                    currentBuild.description = "ROLLBACK to ${env.DEPLOY_TAG}"
                }
            }
        }

        stage('Build') {
            when { expression { params.ACTION == 'deploy' } }
            steps {
                sh 'mvn -B clean compile'
            }
        }

        stage('Unit Test') {
            when { expression { params.ACTION == 'deploy' } }
            steps {
                sh 'mvn -B test'
            }
            post {
                always {
                    junit allowEmptyResults: true, testResults: 'target/surefire-reports/*.xml'
                }
            }
        }

        stage('Docker Build image') {
            when { expression { params.ACTION == 'deploy' } }
            steps {
                sh '''
                    docker build --pull \
                      --label git-commit=$GIT_FULL \
                      --label build-number=$BUILD_NUMBER \
                      -t $IMAGE:$DEPLOY_TAG .
                '''
            }
        }

        stage('Security Scan') {
            when { expression { params.ACTION == 'deploy' } }
            steps {
                // Fails the build on CRITICAL vulnerabilities that have a fix available
                sh '''
                    docker run --rm \
                      -v /var/run/docker.sock:/var/run/docker.sock \
                      -v $HOME/.trivy-cache:/root/.cache/ \
                      $TRIVY_IMAGE image \
                      --severity CRITICAL --ignore-unfixed --exit-code 1 --no-progress \
                      $IMAGE:$DEPLOY_TAG
                '''
            }
        }

        stage('Push Docker Image to Amazon ECR') {
            when { expression { params.ACTION == 'deploy' } }
            steps {
                sh '''
                    aws ecr get-login-password | \
                      docker login --username AWS --password-stdin $ECR_REGISTRY
                    docker push $IMAGE:$DEPLOY_TAG
                '''
            }
        }

        stage('Terraform Init & Validate') {
            steps {
                dir("${TF_DIR}") {
                    sh 'terraform init -input=false'
                    sh 'terraform validate'
                }
            }
        }

        stage('Terraform Plan') {
            steps {
                dir("${TF_DIR}") {
                    sh '''
                        terraform plan -input=false \
                          -var-file=$TF_VARS_FILE \
                          -var "image_tag=$DEPLOY_TAG" \
                          -out=tfplan
                        terraform show -no-color tfplan > tfplan.txt
                    '''
                    archiveArtifacts artifacts: 'tfplan.txt', fingerprint: true
                }
            }
        }

        stage('Approve Production Deploy') {
            steps {
                timeout(time: 30, unit: 'MINUTES') {
                    // Add  submitter: 'user1,user2'  to restrict who can approve
                    input message: "Deploy ${env.DEPLOY_TAG} to PRODUCTION? (Review tfplan.txt under Build Artifacts)",
                          ok: 'Deploy to Production'
                }
            }
        }

        stage('Terraform Apply (Deploy to ECS)') {
            steps {
                dir("${TF_DIR}") {
                    sh 'terraform apply -input=false tfplan'
                    script {
                        env.APP_URL = sh(script: 'terraform output -raw app_url', returnStdout: true).trim()
                    }
                }
            }
        }

        stage('Smoke Test') {
            steps {
                sh '''
                    for i in $(seq 1 18); do   # up to ~3-4 min (new ALB DNS can take a moment)
                      CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$APP_URL" || true)
                      echo "Attempt $i: HTTP $CODE"
                      case "$CODE" in 2*|3*) echo "Smoke test passed: $APP_URL"; exit 0 ;; esac
                      sleep 10
                    done
                    echo "Smoke test FAILED for $APP_URL"
                    exit 1
                '''
            }
        }
    }

    post {
        always {
            sh 'docker image rm $IMAGE:$DEPLOY_TAG 2>/dev/null || true'
            sh 'docker logout $ECR_REGISTRY 2>/dev/null || true'
            sh 'rm -f $TF_DIR/tfplan'
        }
        success {
            echo "PRODUCTION is running ${env.IMAGE}:${env.DEPLOY_TAG} at ${env.APP_URL}"
        }
        failure {
            echo 'Pipeline failed - check the red stage. Production keeps running the previous version unless Terraform Apply had started.'
        }
    }
}
