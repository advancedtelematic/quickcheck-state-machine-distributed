all:
	kubectl create -f deployment.yaml

logs:
	kubectl logs $(shell kubectl get pods --selector=app=master \
		--field-selector=status.phase=Running \
		--output=jsonpath='{.items[0].metadata.name}')
	kubectl logs $(shell kubectl get pods --selector=job-name=slave \
		--field-selector=status.phase=Running \
		--output=jsonpath='{.items[0].metadata.name}')
	kubectl logs $(shell kubectl get pods --selector=job-name=slave \
		--field-selector=status.phase=Running \
		--output=jsonpath='{.items[1].metadata.name}')

clean:
	kubectl delete -f deployment.yaml

image:
	docker build -t advancedtelematic/distributed-tests-prototype:latest .
	docker push advancedtelematic/distributed-tests-prototype:latest

pods:
	watch -n 1 kubectl get pods
