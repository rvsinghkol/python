pipeline{
    agent any
    environment{
        PATH = "/opt/maven/bin:$PATH"
    }    
    stages{
        stage("welcome tooo"){
            steps{
                git credentialsId: 'github', url: 'https://github.com/rvsinghkol/python'
                }
        }
        stage("mvn build"){
            steps{
                sh "mvn clean package"
                sh "mv target/*.war target/world.war"
                 }
        }
        stage("deploy war file"){
            steps{
                sh "cp -rf target/world.war /home/ravi/script/"
                 }
        }
    }
}
